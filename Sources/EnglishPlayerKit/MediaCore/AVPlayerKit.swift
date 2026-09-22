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
    var statusHandler: ((String) -> Void)?

    private(set) var hasVideo = false
    private(set) var duration: Double = 0

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = min(1, max(0, newValue)) }
    }

    func open(url: URL) async throws {
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
        guard await attachIfReady(url, headers: headers, readyTimeout: 20) else {
            throw PlayerError.streamUnsupported(url.lastPathComponent)
        }
    }

    /// 音视频轨都能被系统解码时才直接播。MKV 里的杜比音轨经常在这里失败。
    private func attachIfReady(_ url: URL, headers: [String: String] = [:], readyTimeout: TimeInterval = 2) async -> Bool {
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
        duration = seconds
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
        let upper = duration > 0 ? duration : seconds
        let clamped = min(max(0, seconds), upper)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            handler(seconds)
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        openedURL = nil
        duration = 0
        hasVideo = false
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
