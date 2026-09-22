import Foundation

/// 同一层目录里，主文件名相同的字幕。允许 `名字.en.srt`、`名字.zh.srt` 这种语言后缀。
enum SubtitleMatch {
    static let extensions: Set<String> = ["srt", "ass", "lrc"]
    static let languageTags: Set<String> = ["en", "zh", "eng", "chs", "cht", "cn", "chinese", "english"]

    static func matches(mediaFilename: String, subtitleFilename: String) -> Bool {
        let subtitle = URL(fileURLWithPath: subtitleFilename)
        guard extensions.contains(subtitle.pathExtension.lowercased()) else { return false }
        let mediaStem = URL(fileURLWithPath: mediaFilename).deletingPathExtension().lastPathComponent.lowercased()
        let subtitleStem = subtitle.deletingPathExtension().lastPathComponent.lowercased()
        if subtitleStem == mediaStem { return true }
        guard let dot = subtitleStem.lastIndex(of: ".") else { return false }
        let tag = String(subtitleStem[subtitleStem.index(after: dot)...])
        let base = String(subtitleStem[..<dot])
        return languageTags.contains(tag) && base == mediaStem
    }
}

enum NetdiskCatalog {
    static func parentDirectory(of path: String) -> String {
        if path.isEmpty || path == "/" { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "." { return "/" }
        return parent
    }

    static func playableSorted(_ files: [NetdiskFile]) -> [NetdiskFile] {
        files.filter(\.isPlayable).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func subtitles(for mediaName: String, in files: [NetdiskFile]) -> [NetdiskFile] {
        files.filter { SubtitleMatch.matches(mediaFilename: mediaName, subtitleFilename: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum NetdiskPlayPlan: Equatable {
    case stream(remotePath: String, title: String, url: URL, headers: [String: String], subtitlePaths: [String])
    case remux(remotePath: String, title: String, url: URL, headers: [String: String], subtitlePaths: [String])
    case local(remotePath: String, title: String, cachePath: String, subtitlePaths: [String])
    case blocked(String)
}
