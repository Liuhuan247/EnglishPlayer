import AppKit
import Foundation

enum DictionaryLookup: Equatable {
    case opened(String)
    case notInstalled
    case invalid
}

enum WordToken {
    static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { slice in
            normalize(String(slice))
        }
    }

    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.punctuationCharacters
        allowed.remove(charactersIn: "'’`-")
        let word = trimmed.trimmingCharacters(in: allowed)
        guard !word.isEmpty else { return nil }
        return word
    }
}

struct DictionaryService {
    var opener: (URL) -> Bool
    var availability: (URL) -> Bool

    static func live() -> DictionaryService {
        DictionaryService(
            opener: { NSWorkspace.shared.open($0) },
            availability: { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil }
        )
    }

    static func url(for word: String) -> URL? {
        guard let normalized = WordToken.normalize(word) else { return nil }
        var components = URLComponents()
        components.scheme = "eudic"
        components.host = "dict"
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        components.percentEncodedPath = "/" + encoded
        return components.url
    }

    func lookup(_ raw: String) -> DictionaryLookup {
        guard let url = Self.url(for: raw), let word = WordToken.normalize(raw) else {
            return .invalid
        }
        guard availability(url) else { return .notInstalled }
        return opener(url) ? .opened(word) : .notInstalled
    }
}
