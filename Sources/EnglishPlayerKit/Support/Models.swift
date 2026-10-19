import CryptoKit
import Foundation

enum MediaSource: String, Codable, Equatable {
    case local
    case netdisk
}

enum SubtitleMode: String, Codable, Equatable, CaseIterable {
    case bilingual
    case english
    case chinese
    case hidden

    var title: String {
        switch self {
        case .bilingual: return "双语"
        case .english: return "仅英文"
        case .chinese: return "仅中文"
        case .hidden: return "隐藏"
        }
    }
}

enum LoopMode: String, Codable, Equatable {
    case off
    case sentence
    case ab
}

enum CacheStatus: String, Codable, Equatable {
    case pending
    case downloading
    case paused
    case completed
    case failed
}

enum MediaKind {
    static let video: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "wmv", "asf",
        "ts", "m2ts", "mts", "mpeg", "mpg", "m2v", "3gp", "ogv", "vob"
    ]
    static let audio: Set<String> = ["mp3", "m4a", "wav", "flac", "aac", "aiff", "aif", "caf", "ogg", "opus", "wma"]
    /// 这些封装 AVFoundation 经常能直接播，失败再转换。
    static let systemNative: Set<String> = ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "flac", "aac", "aiff", "aif", "caf"]
    static let subtitle: Set<String> = ["srt", "vtt", "ass", "ssa", "lrc"]

    static func isPlayable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return video.contains(ext) || audio.contains(ext)
    }

    static func isAudio(_ path: String) -> Bool {
        audio.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

/// 倍速按 0.25 对齐，并限制在 0.5–2.0。数字键只映射常用档，菜单里仍可点到中间档。
enum PlaybackRate {
    static let minimum = 0.5
    static let maximum = 2.0
    static let step = 0.25
    static let all: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    static let numberKeys: [Double] = [0.5, 0.75, 1, 1.5, 2]

    static func stepped(_ value: Double) -> Double {
        let scaled = (value / step).rounded()
        let result = scaled * step
        let rounded = (result * 100).rounded() / 100
        return min(maximum, max(minimum, rounded))
    }

    static func display(_ value: Double) -> String {
        let aligned = Self.stepped(value)
        if abs(aligned - floor(aligned)) < 0.001 {
            return String(format: "%.1fx", aligned)
        }
        return String(format: "%gx", aligned)
    }
}

struct MediaItem: Identifiable, Equatable {
    var id: String
    var source: MediaSource
    var path: String
    var cachePath: String?
    var title: String
    var duration: Double
    var lastPosition: Double
    var subtitleOffset: Double
    var subtitleRefs: [String]
    var waveRef: String?
    var updatedAt: Date

    var playableURL: URL? {
        if let cachePath, FileManager.default.fileExists(atPath: cachePath) {
            return URL(fileURLWithPath: cachePath)
        }
        if source == .local, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    var isAudio: Bool { MediaKind.isAudio(cachePath ?? path) }

    static func stableID(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct Sentence: Identifiable, Equatable {
    var id: String
    var mediaID: String
    var index: Int
    var startTime: Double
    var endTime: Double
    var textEn: String
    var textZh: String

    var displayIndex: Int { index + 1 }
}

struct PlaybackRecord: Equatable {
    var mediaID: String
    var position: Double
    var rate: Double
    var loopMode: LoopMode
}

struct CacheEntry: Identifiable, Equatable {
    var mediaID: String
    var netdiskPath: String
    var fsID: Int64
    var localPath: String
    var size: Int64
    var bytesDownloaded: Int64
    var status: CacheStatus
    var dlink: String?
    var dlinkExpiry: Date?
    var updatedAt: Date

    var id: String { mediaID }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

struct AppSettings: Equatable {
    var appearance: AppearanceMode = .system
    var subtitleOffset: Double = 0
    var defaultRate: Double = 1
    var cacheLimitBytes: Int64 = 10 * 1024 * 1024 * 1024
    var subtitleMode: SubtitleMode = .bilingual
    var fontSize: Double = 42
    var preservePitch: Bool = true
    var autoResume: Bool = true
    var continuousPlay: Bool = true
    var shuffle: Bool = false
    var waveformVisible: Bool = true
    var statusBarVisible: Bool = false
    var lastMediaID: String?
    var cacheDirectory: String?

    static let fontRange = 28.0...56.0
}

enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    static func milliseconds(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        let sign = ms > 0 ? "+" : ""
        return "\(sign)\(ms) ms"
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = value
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        if index == 0 { return "\(Int(amount)) \(units[index])" }
        return String(format: "%.1f %@", amount, units[index])
    }
}
