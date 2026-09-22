import Darwin
import Foundation

/// 把网盘上 AVPlayer 打不开的封装边读边转成 HLS。视频尽量原样复制，只把音轨转成 AAC。
enum RemuxLaunch {
    static func arguments(source: URL, headers: [String: String], start: Double, directory: URL, copyVideo: Bool, videoTag: String? = nil) -> [String] {
        var args = ["-hide_banner", "-loglevel", "warning", "-nostdin"]
        let agent = headers["User-Agent"] ?? "pan.baidu.com"
        args += ["-user_agent", agent]
        let headerValue = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        if !headerValue.isEmpty {
            args += ["-headers", headerValue]
        }
        args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        if start > 0.05 {
            args += ["-ss", String(format: "%.3f", start)]
        }
        args += ["-i", source.absoluteString, "-map", "0:v:0?", "-map", "0:a:0?"]
        if copyVideo {
            args += ["-c:v", "copy"]
            if let videoTag {
                args += ["-tag:v", videoTag]
            }
        } else {
            args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p"]
        }
        args += [
            "-c:a", "aac", "-ac", "2", "-b:a", "192k", "-sn",
            "-f", "hls",
            "-hls_time", "2",
            "-hls_list_size", "0",
            "-hls_playlist_type", "event",
            "-hls_segment_type", "fmp4",
            "-hls_fmp4_init_filename", "init.mp4",
            "-hls_flags", "independent_segments+append_list",
            "-hls_segment_filename", directory.appendingPathComponent("seg%05d.m4s").path,
            directory.appendingPathComponent("index.m3u8").path
        ]
        return args
    }

    static func playlistReady(_ text: String) -> Bool {
        text.contains("EXTINF")
    }
}

/// 一次只跑一个 ffmpeg。跳到还没转出来的位置时，停掉当前进程并从那个时间重新开始。
final class LiveRemuxSession: @unchecked Sendable {
    let source: URL
    let headers: [String: String]
    private(set) var probedDuration: Double = 0
    var onDuration: ((Double) -> Void)?
    private var process: Process?
    private var logHandle: FileHandle?
    private var slaveHandle: FileHandle?
    private var logReader: FileHandle?
    private let logLock = NSLock()
    private var hevcTagNeeded = false
    private(set) var lastVideoTag: String?
    private var generation = 0
    private let root: URL

    init(source: URL, headers: [String: String]) {
        self.source = source
        self.headers = headers
        let digest = MediaItem.stableID(for: source.absoluteString)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appendingPathComponent("EnglishPlayer/remux/\(digest)", isDirectory: true)
    }

    func start(at seconds: Double, forceVideoTag: String? = nil) async throws -> URL {
        guard let ffmpeg = MediaCompat.locateFFmpeg() else {
            throw PlayerError.featureUnavailable("需要 ffmpeg 才能在线播放这种封装。把 ffmpeg 放到「应用程序支持/EnglishPlayer/bin」后重试。")
        }
        generation += 1
        let token = generation
        stopProcess()
        let directory = root.appendingPathComponent(String(Int((seconds * 1000).rounded())))
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if token != generation { throw CancellationError() }
        let source = self.source
        let headers = self.headers
        let tokenForProbe = token
        Task.detached(priority: .utility) { [weak self] in
            let value = Self.probeDuration(source: source, headers: headers)
            guard let value, value > 0 else { return }
            self?.acceptDuration(value, token: tokenForProbe)
        }

        let playlist = directory.appendingPathComponent("index.m3u8")
        resetHEVCFlag()
        let ready: URL?
        if let forceVideoTag {
            ready = try await run(ffmpeg, directory: directory, playlist: playlist, start: seconds, copyVideo: true, videoTag: forceVideoTag, token: token)
        } else if let first = try await run(ffmpeg, directory: directory, playlist: playlist, start: seconds, copyVideo: true, videoTag: nil, token: token) {
            if Self.initSegmentNeedsHVC1(directory) || needsHEVCTag() || Self.logNeedsHEVCTag(directory) {
                stopProcess()
                ready = try await run(ffmpeg, directory: directory, playlist: playlist, start: seconds, copyVideo: true, videoTag: "hvc1", token: token)
            } else {
                ready = first
            }
        } else {
            ready = try await secondPass(ffmpeg, directory: directory, playlist: playlist, start: seconds, token: token)
        }
        guard let ready else {
            throw PlayerError.remuxFailed(source.lastPathComponent)
        }
        return ready
    }

    private func secondPass(_ ffmpeg: URL, directory: URL, playlist: URL, start: Double, token: Int) async throws -> URL? {
        if token != generation { throw CancellationError() }
        return try await run(ffmpeg, directory: directory, playlist: playlist, start: start, copyVideo: false, videoTag: nil, token: token)
    }

    private func resetHEVCFlag() {
        logLock.lock()
        hevcTagNeeded = false
        logLock.unlock()
    }

    private func needsHEVCTag() -> Bool {
        logLock.lock()
        defer { logLock.unlock() }
        return hevcTagNeeded
    }

    private static func logNeedsHEVCTag(_ directory: URL) -> Bool {
        let log = directory.appendingPathComponent("ffmpeg.log")
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.contains("not hvc1")
    }

    /// MPEG-TS 里的 HEVC 系统播放器不认。要先打成 fMP4，并且标记成 hvc1。
    private static func initSegmentNeedsHVC1(_ directory: URL) -> Bool {
        let file = directory.appendingPathComponent("init.mp4")
        guard FileManager.default.fileExists(atPath: file.path), let ffmpeg = MediaCompat.locateFFmpeg() else {
            return false
        }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-i", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.contains("Video: hevc") && !text.contains("hvc1")
    }

    func stop() {
        generation += 1
        onDuration = nil
        stopProcess()
    }

    private func acceptDuration(_ value: Double, token: Int) {
        guard token == generation else { return }
        probedDuration = value
        onDuration?(value)
    }

    private func run(_ ffmpeg: URL, directory: URL, playlist: URL, start: Double, copyVideo: Bool, videoTag: String?, token: Int) async throws -> URL? {
        if !copyVideo || videoTag != nil {
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let log = directory.appendingPathComponent("ffmpeg.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = RemuxLaunch.arguments(
            source: source,
            headers: headers,
            start: start,
            directory: directory,
            copyVideo: copyVideo,
            videoTag: videoTag
        )
        let handle = try attachLog(log, process: process)
        lastVideoTag = videoTag
        do {
            try process.run()
        } catch {
            stopProcess()
            return nil
        }
        try? slaveHandle?.close()
        slaveHandle = nil
        self.process = process
        self.logHandle = handle
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if token != generation {
                throw CancellationError()
            }
            if let text = try? String(contentsOf: playlist, encoding: .utf8), RemuxLaunch.playlistReady(text) {
                return playlist
            }
            if !process.isRunning {
                stopProcess()
                return nil
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        stopProcess()
        return nil
    }

    private static func probeDuration(source: URL, headers: [String: String]) -> Double? {
        guard let ffmpeg = MediaCompat.locateFFmpeg() else { return nil }
        let probe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let executable = FileManager.default.isExecutableFile(atPath: probe.path) ? probe : ffmpeg
        let agent = headers["User-Agent"] ?? "pan.baidu.com"
        let arguments: [String]
        if executable == ffmpeg {
            arguments = ["-hide_banner", "-user_agent", agent, "-i", source.absoluteString]
        } else {
            arguments = [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                "-user_agent", agent,
                source.absoluteString
            ]
        }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("englishplayer-probe-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        guard (try? process.run()) != nil else {
            try? handle.close()
            return nil
        }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? handle.close()
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: log)
        if executable == ffmpeg {
            guard let range = text.range(of: #"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) else {
                return nil
            }
            let clock = String(text[range]).replacingOccurrences(of: "Duration:", with: "").trimmingCharacters(in: .whitespaces)
            let parts = clock.split(separator: ":")
            guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else {
                return nil
            }
            return hours * 3600 + minutes * 60 + seconds
        }
        let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// ffmpeg 把日志写到文件时会整块缓冲，「not hvc1」要等进程退出才落盘。
    /// 接到伪终端上才会一行一行出来，这样才能在交给播放器之前改成 hvc1。
    private func attachLog(_ log: URL, process: Process) throws -> FileHandle? {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            let handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle
            process.standardError = handle
            return handle
        }
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        process.standardOutput = slave
        process.standardError = slave
        slaveHandle = slave
        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)
        logReader = master
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let data = master.availableData
                if data.isEmpty { break }
                self?.appendLog(data, to: log)
            }
            try? master.close()
        }
        return nil
    }

    private func appendLog(_ data: Data, to url: URL) {
        logLock.lock()
        defer { logLock.unlock() }
        if let text = String(data: data, encoding: .utf8), text.contains("not hvc1") {
            hevcTagNeeded = true
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    private func stopProcess() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
        try? slaveHandle?.close()
        slaveHandle = nil
        try? logReader?.close()
        logReader = nil
        try? logHandle?.close()
        logHandle = nil
    }
}
