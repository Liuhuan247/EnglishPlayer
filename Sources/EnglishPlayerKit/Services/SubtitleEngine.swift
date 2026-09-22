import Foundation

enum SubtitleFormat: String {
    case srt
    case vtt
    case ass
    case lrc
}

struct SubtitleLoadResult: Equatable {
    var sentences: [Sentence]
    var refs: [String]
    var warning: String?
}

enum SubtitleEngine {
    static func parse(text: String, format: SubtitleFormat) throws -> [Sentence] {
        let cues: [Cue]
        switch format {
        case .lrc:
            cues = parseLRC(text)
        case .ass:
            cues = parseASS(text)
        case .srt, .vtt:
            cues = parseBlocks(text)
        }
        guard !cues.isEmpty else {
            throw PlayerError.subtitleParse("没有解析出任何句子")
        }
        return cues.enumerated().map { index, cue in
            Sentence(
                id: "cue-\(index)",
                mediaID: "",
                index: index,
                startTime: cue.start,
                endTime: cue.end,
                textEn: cue.english,
                textZh: cue.chinese
            )
        }
    }

    static func format(for url: URL) -> SubtitleFormat? {
        switch url.pathExtension.lowercased() {
        case "srt": return .srt
        case "vtt": return .vtt
        case "ass", "ssa": return .ass
        case "lrc": return .lrc
        default: return nil
        }
    }

    static func pair(primary: [Sentence], secondary: [Sentence]) -> [Sentence] {
        guard !secondary.isEmpty else { return primary }
        return primary.map { sentence in
            guard let match = bestMatch(for: sentence, in: secondary) else { return sentence }
            return merge(sentence, match)
        }
    }

    /// 偏移只改播放对齐，不改字幕文件本身。负值表示整体提前。
    static func applying(offset: Double, to sentences: [Sentence]) -> [Sentence] {
        sentences.map { sentence in
            var copy = sentence
            copy.startTime += offset
            copy.endTime += offset
            return copy
        }
    }

    static func load(mediaPath: String, localPath: String? = nil, explicitRefs: [String]) -> SubtitleLoadResult {
        var urls = subtitleURLs(mediaPath: mediaPath, explicitRefs: explicitRefs)
        if urls.isEmpty, let localPath, localPath != mediaPath {
            urls = subtitleURLs(mediaPath: localPath, explicitRefs: [])
        }
        guard !urls.isEmpty else {
            return SubtitleLoadResult(sentences: [], refs: [], warning: "未找到字幕，可以手动指定 SRT 或 LRC。")
        }
        do {
            let grouped = group(urls)
            var sentences = try read(grouped.primary)
            if let chinese = grouped.chinese {
                let extra = try read([chinese])
                sentences = pair(primary: sentences, secondary: extra)
            }
            let refs = (grouped.primary + (grouped.chinese.map { [$0] } ?? [])).map(\.path)
            return SubtitleLoadResult(sentences: sentences, refs: refs, warning: nil)
        } catch let error as PlayerError {
            return SubtitleLoadResult(sentences: [], refs: urls.map(\.path), warning: error.localizedDescription)
        } catch {
            return SubtitleLoadResult(sentences: [], refs: urls.map(\.path), warning: "字幕解析失败，播放仍可继续。")
        }
    }

    static func isMostlyCJK(_ text: String) -> Bool {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                cjk += 1
            } else if scalar.value < 128, CharacterSet.letters.contains(scalar) {
                latin += 1
            }
        }
        return cjk > 0 && cjk >= latin
    }

    private struct Cue {
        var start: Double
        var end: Double
        var english: String
        var chinese: String
    }

    private static func parseBlocks(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [Cue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex]
            let parts = timing.components(separatedBy: "-->")
            guard parts.count >= 2, let start = parseTimestamp(parts[0]), let end = parseTimestamp(parts[1]) else { continue }
            let body = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
            let languages = splitLanguages(body)
            guard !languages.english.isEmpty || !languages.chinese.isEmpty else { continue }
            cues.append(Cue(start: start, end: max(end, start + 0.2), english: languages.english, chinese: languages.chinese))
        }
        return cues
    }

    private static func parseASS(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        var cues: [Cue] = []
        for line in normalized.components(separatedBy: "\n") {
            guard line.hasPrefix("Dialogue:") else { continue }
            let payload = line.dropFirst("Dialogue:".count)
            let fields = payload.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 10 else { continue }
            guard let start = parseTimestamp(fields[1]), let end = parseTimestamp(fields[2]) else { continue }
            let spoken = fields[9].replacingOccurrences(of: "\\N", with: "\n")
            let languages = splitLanguages(spoken)
            cues.append(Cue(start: start, end: max(end, start + 0.2), english: languages.english, chinese: languages.chinese))
        }
        return cues
    }

    private static func parseLRC(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        var stamps: [(time: Double, text: String)] = []
        let pattern = #"\[(\d{1,2}):(\d{2})(?::(\d{2}))?(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var times: [Double] = []
            for match in matches {
                times.append(lrcTime(ns, match))
            }
            let last = matches[matches.count - 1].range
            let lyricStart = last.location + last.length
            var lyric = lyricStart < ns.length ? ns.substring(from: lyricStart) : ""
            lyric = lyric.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            lyric = stripTags(lyric).trimmingCharacters(in: .whitespaces)
            if lyric.isEmpty { continue }
            for time in times {
                stamps.append((time, lyric))
            }
        }
        stamps.sort { $0.time < $1.time }
        var cues: [Cue] = []
        for (index, stamp) in stamps.enumerated() {
            let next = index + 1 < stamps.count ? stamps[index + 1].time : stamp.time + 5
            let end = max(stamp.time + 0.4, next)
            let languages = splitLanguages(stamp.text)
            cues.append(Cue(start: stamp.time, end: end, english: languages.english, chinese: languages.chinese))
        }
        return cues
    }

    private static func lrcTime(_ line: NSString, _ match: NSTextCheckingResult) -> Double {
        func number(_ index: Int) -> Double {
            guard match.range(at: index).location != NSNotFound else { return 0 }
            return Double(line.substring(with: match.range(at: index))) ?? 0
        }
        let head = number(1)
        let second = number(2)
        let hasHour = match.range(at: 3).location != NSNotFound
        if hasHour {
            let seconds = number(3)
            return head * 3600 + second * 60 + seconds + fraction(line, match, group: 4)
        }
        return head * 60 + second + fraction(line, match, group: 4)
    }

    private static func fraction(_ line: NSString, _ match: NSTextCheckingResult, group: Int) -> Double {
        guard match.range(at: group).location != NSNotFound else { return 0 }
        let digits = line.substring(with: match.range(at: group))
        guard let value = Double(digits), !digits.isEmpty else { return 0 }
        return value / pow(10, Double(digits.count))
    }

    private static func parseTimestamp(_ raw: String) -> Double? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first?
            .replacingOccurrences(of: ",", with: ".") ?? ""
        let parts = cleaned.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        let secondsPart = parts.last ?? "0"
        let seconds = Double(secondsPart) ?? 0
        if parts.count == 3 {
            let hour = Double(parts[0]) ?? 0
            let minute = Double(parts[1]) ?? 0
            return hour * 3600 + minute * 60 + seconds
        }
        if parts.count == 2 {
            let minute = Double(parts[0]) ?? 0
            return minute * 60 + seconds
        }
        if parts.count == 1 {
            return seconds
        }
        return nil
    }

    private static func splitLanguages(_ raw: String) -> (english: String, chinese: String) {
        let lines = raw
            .components(separatedBy: "\n")
            .map { stripTags($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var english: [String] = []
        var chinese: [String] = []
        for line in lines {
            if isMostlyCJK(line) {
                chinese.append(line)
            } else {
                english.append(line)
            }
        }
        return (english.joined(separator: "\n"), chinese.joined(separator: "\n"))
    }

    private static func stripTags(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func bestMatch(for sentence: Sentence, in candidates: [Sentence]) -> Sentence? {
        let duration = max(0.2, sentence.endTime - sentence.startTime)
        let ranked = candidates
            .map { ($0, overlap(sentence, $0)) }
            .filter { $0.1 > duration * 0.2 }
            .max { $0.1 < $1.1 }
        return ranked?.0
    }

    private static func overlap(_ lhs: Sentence, _ rhs: Sentence) -> Double {
        max(0, min(lhs.endTime, rhs.endTime) - max(lhs.startTime, rhs.startTime))
    }

    private static func merge(_ primary: Sentence, _ extra: Sentence) -> Sentence {
        var merged = primary
        let extraEnglish = extra.textEn.isEmpty && !extra.textZh.isEmpty && !isMostlyCJK(extra.textZh) ? extra.textZh : extra.textEn
        let extraChinese = extra.textZh.isEmpty && isMostlyCJK(extra.textEn) ? extra.textEn : extra.textZh
        if merged.textEn.isEmpty { merged.textEn = extraEnglish }
        if merged.textZh.isEmpty { merged.textZh = extraChinese }
        return merged
    }

    private static func subtitleURLs(mediaPath: String, explicitRefs: [String]) -> [URL] {
        let explicit = explicitRefs.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !explicit.isEmpty { return explicit }
        let mediaURL = URL(fileURLWithPath: mediaPath)
        let stem = mediaURL.deletingPathExtension().lastPathComponent.lowercased()
        let directory = mediaURL.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { file in
            guard format(for: file) != nil else { return false }
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            return name == stem || name.hasPrefix(stem + ".")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func group(_ urls: [URL]) -> (primary: [URL], chinese: URL?) {
        func role(_ url: URL) -> String {
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            if name.contains(".zh") || name.contains(".chs") || name.contains(".cht") || name.contains(".cn") || name.contains(".chinese") {
                return "zh"
            }
            if name.contains(".en") || name.contains(".eng") || name.contains(".english") {
                return "en"
            }
            return "primary"
        }
        let chinese = urls.first { role($0) == "zh" }
        let preferred = urls.first { role($0) == "primary" } ?? urls.first { role($0) == "en" }
        if let preferred {
            return ([preferred], chinese)
        }
        if let chinese {
            return ([chinese], nil)
        }
        return (urls.isEmpty ? [] : [urls[0]], nil)
    }

    private static func read(_ urls: [URL]) throws -> [Sentence] {
        guard !urls.isEmpty else {
            throw PlayerError.subtitleParse("没有可用的字幕文件")
        }
        var sentences: [Sentence] = []
        for url in urls {
            guard let format = format(for: url) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try parse(text: text, format: format)
            if sentences.isEmpty {
                sentences = parsed
            } else {
                sentences = pair(primary: sentences, secondary: parsed)
            }
        }
        return sentences
    }
}
