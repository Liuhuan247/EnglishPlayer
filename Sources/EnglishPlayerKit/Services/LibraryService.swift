import Combine
import Foundation

@MainActor
final class LibraryService: ObservableObject {
    @Published private(set) var playlist: [MediaItem] = []
    @Published private(set) var settings = AppSettings()

    private let store: SQLiteStore

    init(store: SQLiteStore) {
        self.store = store
        reload()
    }

    func reload() {
        loadSettings()
        let ids = (try? store.playlistIDs()) ?? []
        playlist = ids.compactMap { try? store.media(id: $0) }
    }

    func media(id: String) -> MediaItem? {
        try? store.media(id: id)
    }

    @discardableResult
    func importLocal(urls: [URL]) -> [MediaItem] {
        var imported: [MediaItem] = []
        for url in urls where MediaKind.isPlayable(url) {
            imported.append(upsertLocal(url))
        }
        appendToPlaylist(imported.map(\.id))
        return imported
    }

    @discardableResult
    func importCached(remotePath: String, localPath: String, title: String) -> MediaItem {
        let id = MediaItem.stableID(for: remotePath)
        let existing = try? store.media(id: id)
        let item = MediaItem(
            id: id,
            source: .netdisk,
            path: remotePath,
            cachePath: localPath,
            title: title,
            duration: existing?.duration ?? 0,
            lastPosition: existing?.lastPosition ?? 0,
            subtitleOffset: existing?.subtitleOffset ?? settings.subtitleOffset,
            subtitleRefs: existing?.subtitleRefs ?? [],
            waveRef: existing?.waveRef,
            updatedAt: Date()
        )
        save(item)
        appendToPlaylist([id])
        return item
    }

    @discardableResult
    func upsertNetdisk(remotePath: String, title: String, cachePath: String?, subtitleRefs: [String]) -> MediaItem {
        let id = MediaItem.stableID(for: remotePath)
        let existing = try? store.media(id: id)
        let item = MediaItem(
            id: id,
            source: .netdisk,
            path: remotePath,
            cachePath: cachePath,
            title: title,
            duration: existing?.duration ?? 0,
            lastPosition: existing?.lastPosition ?? 0,
            subtitleOffset: existing?.subtitleOffset ?? settings.subtitleOffset,
            subtitleRefs: subtitleRefs.isEmpty ? (existing?.subtitleRefs ?? []) : subtitleRefs,
            waveRef: existing?.waveRef,
            updatedAt: Date()
        )
        save(item)
        return item
    }

    func savePlayback(mediaID: String, position: Double, rate: Double, loopMode: LoopMode) {
        try? store.savePlayback(PlaybackRecord(mediaID: mediaID, position: position, rate: rate, loopMode: loopMode))
    }

    func playback(mediaID: String) -> PlaybackRecord? {
        try? store.playback(mediaID: mediaID)
    }

    func save(_ item: MediaItem) {
        try? store.upsertMedia(item)
        if let index = playlist.firstIndex(where: { $0.id == item.id }) {
            playlist[index] = item
        }
    }

    func replaceSentences(mediaID: String, _ sentences: [Sentence]) {
        try? store.replaceSentences(mediaID: mediaID, sentences)
    }

    func sentences(mediaID: String) -> [Sentence] {
        (try? store.sentences(mediaID: mediaID)) ?? []
    }

    func recentMedia(limit: Int = 6) -> [MediaItem] {
        let all = (try? store.allMedia()) ?? []
        return all.filter { item in
            if item.source == .local {
                return FileManager.default.fileExists(atPath: item.path)
            }
            return true
        }.prefix(limit).map { $0 }
    }

    func removeFromPlaylist(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        playlist.remove(at: index)
        try? store.setPlaylist(playlist.map(\.id))
    }

    func movePlaylist(from source: IndexSet, to destination: Int) {
        var items = playlist
        let moving = source.sorted().map { items[$0] }
        for index in source.sorted(by: >) {
            items.remove(at: index)
        }
        var insertAt = destination
        for index in source where index < destination {
            insertAt -= 1
        }
        let clamped = min(max(0, insertAt), items.count)
        items.insert(contentsOf: moving, at: clamped)
        playlist = items
        try? store.setPlaylist(items.map(\.id))
    }

    func remember(mediaID: String?) {
        settings.lastMediaID = mediaID
        write("last_media_id", mediaID ?? "")
    }

    func setAppearance(_ mode: AppearanceMode) {
        settings.appearance = mode
        write("appearance", mode.rawValue)
    }

    func setSubtitleOffset(_ value: Double) {
        settings.subtitleOffset = value
        write("subtitle_offset", String(value))
    }

    func setDefaultRate(_ value: Double) {
        settings.defaultRate = PlaybackRate.stepped(value)
        write("default_rate", String(settings.defaultRate))
    }

    func setCacheLimit(_ bytes: Int64) {
        settings.cacheLimitBytes = max(256 * 1024 * 1024, bytes)
        write("cache_limit", String(settings.cacheLimitBytes))
    }

    func setSubtitleMode(_ mode: SubtitleMode) {
        settings.subtitleMode = mode
        write("subtitle_mode", mode.rawValue)
    }

    func setFontSize(_ size: Double) {
        let clamped = min(AppSettings.fontRange.upperBound, max(AppSettings.fontRange.lowerBound, size))
        settings.fontSize = clamped
        write("font_size", String(clamped))
    }

    func setPreservePitch(_ enabled: Bool) {
        settings.preservePitch = enabled
        write("preserve_pitch", enabled ? "1" : "0")
    }

    func setAutoResume(_ enabled: Bool) {
        settings.autoResume = enabled
        write("auto_resume", enabled ? "1" : "0")
    }

    func setContinuousPlay(_ enabled: Bool) {
        settings.continuousPlay = enabled
        write("continuous_play", enabled ? "1" : "0")
    }

    func setShuffle(_ enabled: Bool) {
        settings.shuffle = enabled
        write("shuffle", enabled ? "1" : "0")
    }

    func setWaveformVisible(_ enabled: Bool) {
        settings.waveformVisible = enabled
        write("waveform_visible", enabled ? "1" : "0")
    }

    func setStatusBarVisible(_ enabled: Bool) {
        settings.statusBarVisible = enabled
        write("status_bar", enabled ? "1" : "0")
    }

    func setCacheDirectory(_ path: String?) {
        settings.cacheDirectory = path
        write("cache_directory", path ?? "")
    }

    private func upsertLocal(_ url: URL) -> MediaItem {
        if let existing = try? store.media(path: url.path) {
            return existing
        }
        let item = MediaItem(
            id: MediaItem.stableID(for: url.path),
            source: .local,
            path: url.path,
            cachePath: nil,
            title: url.deletingPathExtension().lastPathComponent,
            duration: 0,
            lastPosition: 0,
            subtitleOffset: settings.subtitleOffset,
            subtitleRefs: [],
            waveRef: nil,
            updatedAt: Date()
        )
        save(item)
        return item
    }

    private func appendToPlaylist(_ ids: [String]) {
        var current = playlist.map(\.id)
        for id in ids where !current.contains(id) {
            current.append(id)
        }
        try? store.setPlaylist(current)
        playlist = current.compactMap { try? store.media(id: $0) }
    }

    private func loadSettings() {
        let map = (try? store.allSettings()) ?? [:]
        var value = AppSettings()
        if let raw = map["appearance"], let mode = AppearanceMode(rawValue: raw) { value.appearance = mode }
        if let raw = map["subtitle_offset"], let number = Double(raw) { value.subtitleOffset = number }
        if let raw = map["default_rate"], let number = Double(raw) { value.defaultRate = PlaybackRate.stepped(number) }
        if let raw = map["cache_limit"], let number = Int64(raw) { value.cacheLimitBytes = number }
        if let raw = map["subtitle_mode"], let mode = SubtitleMode(rawValue: raw) { value.subtitleMode = mode }
        if let raw = map["font_size"], let number = Double(raw) { value.fontSize = number }
        if let raw = map["preserve_pitch"] { value.preservePitch = raw != "0" }
        if let raw = map["auto_resume"] { value.autoResume = raw != "0" }
        if let raw = map["continuous_play"] { value.continuousPlay = raw != "0" }
        if let raw = map["shuffle"] { value.shuffle = raw == "1" }
        if let raw = map["waveform_visible"] { value.waveformVisible = raw != "0" }
        if let raw = map["status_bar"] { value.statusBarVisible = raw == "1" }
        if let raw = map["last_media_id"], !raw.isEmpty { value.lastMediaID = raw }
        if let raw = map["cache_directory"], !raw.isEmpty { value.cacheDirectory = raw }
        settings = value
    }

    private func write(_ key: String, _ value: String) {
        try? store.setSetting(key, value)
    }
}
