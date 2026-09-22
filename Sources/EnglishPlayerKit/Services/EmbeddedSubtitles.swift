import Foundation

/// 从 MKV 等容器里抽出文字字幕。只映射字幕轨，音视频按包长跳过，不用把整集下完。
enum EmbeddedSubtitles {
    struct Track: Equatable {
        var ordinal: Int
        var language: String
        var codec: String
    }

    private static let imageCodecs: Set<String> = [
        "hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvdsub", "vobsub", "xsub", "dvb_subtitle", "dvbsub"
    ]

    static func tracks(in ffmpegLog: String) -> [Track] {
        let pattern = #"#\d+:\d+(?:\[[^\]]+\])?(?:\(([A-Za-z0-9]+)\))?: Subtitle: ([A-Za-z0-9_]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = ffmpegLog as NSString
        let matches = regex.matches(in: ffmpegLog, range: NSRange(location: 0, length: text.length))
        return matches.enumerated().map { index, match in
            let language = match.range(at: 1).location == NSNotFound ? "" : text.substring(with: match.range(at: 1))
            let codec = text.substring(with: match.range(at: 2))
            return Track(ordinal: index, language: language.lowercased(), codec: codec.lowercased())
        }
    }

    /// 优先英语 + 中文两条文字轨。图片字幕（PGS、VobSub）没有文字，不能按句播放。
    static func selection(from tracks: [Track]) -> (primary: Int, secondary: Int?)? {
        let text = tracks.filter { !imageCodecs.contains($0.codec) }
        guard let first = text.first else { return nil }
        let chinese = text.first { role($0.language) == "zh" }
        let english = text.first { role($0.language) == "en" }
        if let english, let chinese, english.ordinal != chinese.ordinal {
            return (english.ordinal, chinese.ordinal)
        }
        if let english { return (english.ordinal, nil) }
        if let chinese { return (chinese.ordinal, nil) }
        if text.count >= 2 {
            return (first.ordinal, text[1].ordinal)
        }
        return (first.ordinal, nil)
    }

    static func extract(url: URL, headers: [String: String]) async -> SubtitleLoadResult {
        let job = Job()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                extractBlocking(url: url, headers: headers, job: job)
            }.value
        } onCancel: {
            job.stop()
        }
    }

    private static func role(_ language: String) -> String {
        switch language {
        case "chi", "zho", "zh", "chs", "cht", "cn", "chinese", "cmn":
            return "zh"
        case "eng", "en", "english":
            return "en"
        default:
            return ""
        }
    }

    private static func extractBlocking(url: URL, headers: [String: String], job: Job) -> SubtitleLoadResult {
        guard let ffmpeg = MediaCompat.locateFFmpeg() else {
            return SubtitleLoadResult(sentences: [], refs: [], warning: "需要 ffmpeg 才能读取片内字幕。")
        }
        let deadline = Date().addingTimeInterval(300)
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { job.stop() }
        guard let listed = run(ffmpeg, inputArguments(url: url, headers: headers), job: job, capture: .error) else {
            return SubtitleLoadResult(sentences: [], refs: [], warning: "没有读到片内字幕。")
        }
        guard Date() < deadline else {
            return SubtitleLoadResult(sentences: [], refs: [], warning: "片内字幕读取超时。可以手动指定 SRT。")
        }
        guard let chosen = selection(from: tracks(in: listed)) else {
            return SubtitleLoadResult(sentences: [], refs: [], warning: "没有可按句播放的文字字幕。图片字幕需要外挂 SRT。")
        }
        guard let primaryText = subtitleText(ffmpeg, url: url, headers: headers, ordinal: chosen.primary, job: job),
              !primaryText.isEmpty else {
            return SubtitleLoadResult(sentences: [], refs: [], warning: "片内字幕没有抽出来。可以手动指定 SRT。")
        }
        guard var primary = try? SubtitleEngine.parse(text: primaryText, format: .srt), !primary.isEmpty else {
            return SubtitleLoadResult(sentences: [], refs: [], warning: "片内字幕没有解析出句子。")
        }
        if let secondary = chosen.secondary,
           let extraText = subtitleText(ffmpeg, url: url, headers: headers, ordinal: secondary, job: job),
           let extra = try? SubtitleEngine.parse(text: extraText, format: .srt),
           !extra.isEmpty {
            if sampleIsChinese(primary), !sampleIsChinese(extra) {
                primary = SubtitleEngine.pair(primary: extra, secondary: primary)
            } else {
                primary = SubtitleEngine.pair(primary: primary, secondary: extra)
            }
        }
        return SubtitleLoadResult(sentences: primary, refs: [], warning: nil)
    }

    private static func sampleIsChinese(_ sentences: [Sentence]) -> Bool {
        let sample = sentences.prefix(8).map { $0.textEn + $0.textZh }.joined()
        return SubtitleEngine.isMostlyCJK(sample)
    }

    private static func subtitleText(_ ffmpeg: URL, url: URL, headers: [String: String], ordinal: Int, job: Job) -> String? {
        var arguments = inputArguments(url: url, headers: headers)
        arguments += ["-map", "0:s:\(ordinal)", "-f", "srt", "-"]
        guard let text = run(ffmpeg, arguments, job: job, capture: .output) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func inputArguments(url: URL, headers: [String: String]) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-probesize", "5000000", "-analyzeduration", "2000000"]
        if let agent = headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value, !agent.isEmpty {
            arguments += ["-user_agent", agent]
        }
        let extra = headers.filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
        if !extra.isEmpty {
            let block = extra.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            arguments += ["-headers", block]
        }
        arguments += ["-i", url.isFileURL ? url.path : url.absoluteString]
        return arguments
    }

    private enum Capture {
        case output
        case error
    }

    private static func run(_ ffmpeg: URL, _ arguments: [String], job: Job, capture: Capture) -> String? {
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        let wanted = capture == .output ? output : error
        let ignored = capture == .output ? error : output
        let collected = LockedText()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let data = wanted.fileHandleForReading.readDataToEndOfFile()
            collected.set(String(data: data, encoding: .utf8) ?? "")
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            _ = ignored.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        job.adopt(process)
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        group.wait()
        if job.wasStopped { return nil }
        return collected.value
    }

    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false

        var wasStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func adopt(_ process: Process) {
            lock.lock()
            let shouldStop = stopped
            self.process = process
            lock.unlock()
            if shouldStop { process.terminate() }
        }

        func stop() {
            lock.lock()
            stopped = true
            let process = process
            lock.unlock()
            process?.terminate()
        }
    }

    private final class LockedText: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        var value: String {
            lock.lock()
            defer { lock.unlock() }
            return text
        }

        func set(_ text: String) {
            lock.lock()
            self.text = text
            lock.unlock()
        }
    }
}
