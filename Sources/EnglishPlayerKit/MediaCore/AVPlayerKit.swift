import AVFoundation
import AppKit
import Foundation

/// macOS 上的 MediaCore。倍速走 timeDomain 以保持音高；句界 seek 用零容差，避免被关键帧吸走。
@MainActor
final class AVPlayerKit: MediaCoreProtocol {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var pitchPreservation = true
    private var desiredRate: Float = 1
    private var previewLayer: AVPlayerLayer?
    private weak var previewHost: NSView?
    private(set) var openedURL: URL?
    private var remux: LiveRemuxSession?
    private var loopback: LoopbackFileServer?
    private let remuxClock = RemuxClock()
    private var remuxDuration: Double = 0
    var statusHandler: ((String) -> Void)?

    private(set) var hasVideo = false
    private(set) var duration: Double = 0

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        let playerSeconds = seconds.isFinite ? seconds : 0
        return remuxClock.current + playerSeconds
    }

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = min(1, max(0, newValue)) }
    }

    func open(url: URL) async throws {
        stopRemux()
        let ext = url.pathExtension.lowercased()
        guard MediaKind.isPlayable(url) else {
            throw PlayerError.unsupportedFormat(ext)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlayerError.fileMissing
        }

        if await attachIfReady(url) {
            return
        }

        statusHandler?("正在转换「\(url.lastPathComponent)」，系统播放器不能直接播这个封装…")
        let prepared = try await MediaCompat.prepare(url)
        guard await attachIfReady(prepared) else {
            throw PlayerError.damagedFile(url.lastPathComponent)
        }
    }

    func openRemote(url: URL, headers: [String: String]) async throws {
        stopRemux()
        guard await attachIfReady(url, headers: headers, readyTimeout: 20) else {
            throw PlayerError.streamUnsupported(url.lastPathComponent)
        }
    }

    func openRemux(url: URL, headers: [String: String]) async throws {
        stopRemux()
        let session = LiveRemuxSession(source: url, headers: headers)
        session.onDuration = { [weak self] value in
            Task { @MainActor in
                guard let self, self.remux != nil else { return }
                self.remuxDuration = value
                self.duration = value
            }
        }
        statusHandler?("正在转换「\(url.lastPathComponent)」，马上就能播…")
        remux = session
        do {
            var playlist = try await session.start(at: 0)
            remuxClock.set(0)
            remuxDuration = session.probedDuration
            var playURL = try await publish(playlist)
            var opened = await attachIfReady(playURL, readyTimeout: 20, openEnded: true)
            if !opened, session.lastVideoTag == nil {
                playlist = try await session.start(at: 0, forceVideoTag: "hvc1")
                remuxClock.set(0)
                remuxDuration = session.probedDuration
                playURL = try await publish(playlist)
                opened = await attachIfReady(playURL, readyTimeout: 20, openEnded: true)
            }
            guard opened else {
                stopRemux()
                throw PlayerError.remuxFailed(url.lastPathComponent)
            }
            if remuxDuration > 0 {
                duration = remuxDuration
            }
        } catch {
            stopRemux()
            throw error
        }
    }

    /// 音视频轨都能被系统解码时才直接播。MKV 里的杜比音轨经常在这里失败。
    /// 边转边播的 m3u8 还在增长，总时长经常是无限的，不能用本地文件那套时长门槛。
    private func attachIfReady(_ url: URL, headers: [String: String] = [:], readyTimeout: TimeInterval = 2, openEnded: Bool = false) async -> Bool {
        if openEnded {
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = pitchPreservation ? .timeDomain : .varispeed
            player.replaceCurrentItem(with: item)
            guard await itemIsReady(item, timeout: readyTimeout) else {
                player.replaceCurrentItem(with: nil)
                return false
            }
            let videoTracks = (try? await item.asset.loadTracks(withMediaType: .video)) ?? []
            hasVideo = !videoTracks.isEmpty
            let seconds = item.duration.seconds
            if seconds.isFinite, seconds > 0 {
                duration = seconds
            }
            player.defaultRate = desiredRate
            openedURL = url
            if let host = previewHost {
                attachPreview(to: host)
            }
            return true
        }

        var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let durationTime = (try? await asset.load(.duration)) ?? .zero
        let seconds = durationTime.seconds
        guard playable, seconds.isFinite, seconds > 0 else { return false }

        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { return false }
        for track in videoTracks + audioTracks {
            let trackPlayable = (try? await track.load(.isPlayable)) ?? false
            if !trackPlayable { return false }
        }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = pitchPreservation ? .timeDomain : .varispeed
        player.replaceCurrentItem(with: item)
        guard await itemIsReady(item, timeout: readyTimeout) else {
            player.replaceCurrentItem(with: nil)
            return false
        }

        hasVideo = !videoTracks.isEmpty
        if seconds.isFinite, seconds > 0 {
            duration = seconds
        }
        player.defaultRate = desiredRate
        openedURL = url
        if let host = previewHost {
            attachPreview(to: host)
        }
        return true
    }

    private func itemIsReady(_ item: AVPlayerItem, timeout: TimeInterval) async -> Bool {
        if item.status == .readyToPlay { return true }
        if item.status == .failed { return false }
        let gate = ResumeGate()
        return await withCheckedContinuation { continuation in
            var observation: NSKeyValueObservation?
            observation = item.observe(\.status, options: [.new]) { item, _ in
                let status = item.status
                guard status == .readyToPlay || status == .failed else { return }
                gate.resume {
                    observation?.invalidate()
                    continuation.resume(returning: status == .readyToPlay)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                gate.resume {
                    observation?.invalidate()
                    continuation.resume(returning: item.status == .readyToPlay)
                }
            }
        }
    }

    func play() {
        player.play()
        player.rate = desiredRate
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) async {
        if remux != nil {
            await seekRemux(to: seconds)
            return
        }
        let upper = duration > 0 ? duration : seconds
        let clamped = min(max(0, seconds), upper)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func seekRemux(to seconds: Double) async {
        guard let remux else { return }
        let upper = remuxDuration > 0 ? remuxDuration : max(duration, seconds)
        let target = min(max(0, seconds), upper)
        let relative = target - remuxClock.current
        let seekableEnd = player.currentItem?.seekableTimeRanges
            .map(\.timeRangeValue)
            .map { $0.start.seconds + $0.duration.seconds }
            .max() ?? 0
        if relative >= -0.05, seekableEnd > 0.2, relative <= seekableEnd - 0.3 {
            let time = CMTime(seconds: max(0, relative), preferredTimescale: 600)
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        let wasPlaying = player.timeControlStatus == .playing || player.rate > 0
        statusHandler?("正在转到 \(TimeFormat.clock(target))…")
        do {
            let playlist = try await remux.start(at: target)
            remuxClock.set(target)
            let playURL = try await publish(playlist)
            guard await attachIfReady(playURL, readyTimeout: 20, openEnded: true) else { return }
            if remuxDuration > 0 { duration = remuxDuration }
            if wasPlaying { play() }
        } catch {
            statusHandler?((error as? LocalizedError)?.errorDescription ?? "无法跳到这个位置")
        }
    }

    func setRate(_ rate: Double) {
        desiredRate = Float(PlaybackRate.stepped(rate))
        player.defaultRate = desiredRate
        if player.timeControlStatus == .playing {
            player.rate = desiredRate
        }
    }

    func setPitchPreservation(_ enabled: Bool) {
        pitchPreservation = enabled
        player.currentItem?.audioTimePitchAlgorithm = enabled ? .timeDomain : .varispeed
    }

    func setTimeObserver(_ handler: @escaping (Double) -> Void) {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            let origin = self?.remuxClock.current ?? 0
            handler(origin + seconds)
        }
    }

    func attachPreview(to view: NSView) {
        previewHost = view
        view.wantsLayer = true
        if previewLayer == nil {
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            previewLayer = layer
        }
        if previewLayer?.superlayer !== view.layer {
            previewLayer?.removeFromSuperlayer()
            if let previewLayer {
                view.layer?.addSublayer(previewLayer)
            }
        }
        layoutPreview()
    }

    func layoutPreview() {
        previewLayer?.frame = previewHost?.bounds ?? .zero
        previewHost?.layer?.backgroundColor = NSColor.black.cgColor
    }

    func close() {
        stopRemux()
        player.pause()
        player.replaceCurrentItem(with: nil)
        openedURL = nil
        duration = 0
        hasVideo = false
    }

    private func publish(_ playlist: URL) async throws -> URL {
        loopback?.stop()
        let server = LoopbackFileServer(root: playlist.deletingLastPathComponent())
        let base = try await server.start()
        loopback = server
        return base.appendingPathComponent(playlist.lastPathComponent)
    }

    private func stopRemux() {
        loopback?.stop()
        loopback = nil
        remux?.stop()
        remux = nil
        remuxClock.set(0)
        remuxDuration = 0
    }
}

/// 边转边播的时间零点。播放器回调不在主线程隔离里，所以单独用锁保存。
private final class RemuxClock: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: Double = 0

    var current: Double {
        lock.lock()
        defer { lock.unlock() }
        return origin
    }

    func set(_ value: Double) {
        lock.lock()
        origin = value
        lock.unlock()
    }
}

/// `AVPlayerItem.status` 的回调和超时可能同时到达，只让其中一个结束等待。
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
