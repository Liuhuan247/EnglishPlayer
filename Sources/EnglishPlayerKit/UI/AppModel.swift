import AppKit
import Combine
import SwiftUI

@MainActor
public final class AppModel: ObservableObject {
    nonisolated public let objectWillChange = ObservableObjectPublisher()
    @Published public var section: AppSection = .player
    @Published public var toast: String?

    let library: LibraryService
    let session: PlaybackSession
    let netdisk: NetdiskService
    let dictionary: DictionaryService
    let cache: CacheManager

    private var toastTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var didRestore = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        library: LibraryService,
        session: PlaybackSession,
        netdisk: NetdiskService,
        dictionary: DictionaryService,
        cache: CacheManager
    ) {
        self.library = library
        self.session = session
        self.netdisk = netdisk
        self.dictionary = dictionary
        self.cache = cache
        for object in [session.objectWillChange, library.objectWillChange, netdisk.objectWillChange] {
            object.sink { [weak self] _ in
                self?.objectWillChange.send()
            }.store(in: &cancellables)
        }
        session.onFinished = { [weak self] in
            self?.playNextAfterFinish()
        }
        netdisk.onFileReady = { [weak self] remote, local, title in
            guard let self else { return }
            let item = self.library.importCached(remotePath: remote, localPath: local, title: title)
            self.showToast("已加入播放列表")
            if self.session.currentItem == nil {
                Task { await self.session.open(item, autoplay: false) }
            }
        }
    }

    public static func live() -> AppModel {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EnglishPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let database = support.appendingPathComponent("library.sqlite")
        let store = (try? SQLiteStore(path: database.path))
            ?? (try? SQLiteStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("EnglishPlayer.sqlite").path))
        guard let store else {
            fatalError("无法创建本地资料库")
        }
        let library = LibraryService(store: store)
        let cacheDirectory: URL
        if let custom = library.settings.cacheDirectory {
            cacheDirectory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            cacheDirectory = support.appendingPathComponent("Cache", isDirectory: true)
        }
        let cache = (try? CacheManager(directory: cacheDirectory))
            ?? (try? CacheManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent("EnglishPlayerCache", isDirectory: true)))
        guard let cache else {
            fatalError("无法创建缓存目录")
        }
        let waveforms = WaveformService(directory: support.appendingPathComponent("Waveforms", isDirectory: true))
        let session = PlaybackSession(core: AVPlayerKit(), library: library, waveforms: waveforms)
        let netdisk = NetdiskService(store: store, cache: cache, credentials: KeychainStore())
        return AppModel(
            library: library,
            session: session,
            netdisk: netdisk,
            dictionary: .live(),
            cache: cache
        )
    }

    public func restoreIfNeeded() async {
        guard !didRestore else { return }
        didRestore = true
        installKeys()
        if library.settings.autoResume,
           let id = library.settings.lastMediaID,
           let item = library.media(id: id) {
            await session.open(item, autoplay: false)
        }
        await netdisk.restoreSession()
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if self.toast == text { self.toast = nil }
        }
    }

    func importURLs(_ urls: [URL]) async {
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
        }
        let playable = urls.filter(MediaKind.isPlayable)
        let subtitles = urls.filter { MediaKind.subtitle.contains($0.pathExtension.lowercased()) }
        if playable.isEmpty && subtitles.isEmpty {
            showToast("没有可播放的音视频。支持 MP4、MOV、MKV、AVI、WebM、MP3、M4A、WAV、FLAC。")
            return
        }
        if !playable.isEmpty {
            let items = library.importLocal(urls: playable)
            if let first = items.first {
                await session.open(first, autoplay: true)
                section = .player
                if session.currentItem?.id == first.id {
                    showToast("已加入 \(items.count) 个文件")
                } else if let banner = session.banner, !banner.isEmpty {
                    showToast(banner)
                }
            }
        }
        if let subtitle = subtitles.first {
            session.useSubtitle(at: subtitle)
            if let banner = session.banner { showToast(banner) }
        }
    }

    func openFilesPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择英语视频或音频，也可以一起选中同目录字幕。"
        panel.prompt = "打开"
        guard panel.runModal() == .OK else { return }
        Task { await importURLs(panel.urls) }
    }

    func openSubtitlePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 SRT、VTT、ASS 或 LRC 字幕。"
        panel.prompt = "载入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        session.useSubtitle(at: url)
        showToast(session.banner ?? "已加载字幕")
    }

    func chooseCacheDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择"
        panel.message = "之后下载的网盘文件会放在这个目录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try cache.setDirectory(url)
            library.setCacheDirectory(url.path)
            showToast("缓存目录已更新")
        } catch {
            showToast("无法使用这个目录")
        }
    }

    func clearCache() {
        let protected = Set([session.currentItem?.cachePath].compactMap { $0 })
        do {
            let freed = try netdisk.clearCache(protected: protected)
            _ = try cache.purge(keepingUnder: 0, protected: protected)
            showToast(freed > 0 ? "已清理 \(ByteFormat.string(freed))" : "没有可清理的缓存")
        } catch {
            showToast("清理缓存失败")
        }
    }

    func play(_ item: MediaItem) {
        Task {
            await session.open(item, autoplay: true)
            section = .player
        }
    }

    func playNetdisk(_ file: NetdiskFile) {
        netdisk.message = "正在连接「\(file.name)」…"
        Task {
            switch await netdisk.preparePlayback(file) {
            case .stream(let remotePath, let title, let url, let headers, let subtitlePaths):
                let item = library.upsertNetdisk(remotePath: remotePath, title: title, cachePath: nil, subtitleRefs: subtitlePaths)
                await session.openRemote(item, url: url, headers: headers, autoplay: true)
                if session.currentItem?.path == remotePath {
                    showToast("正在在线播放「\(title)」")
                } else {
                    let text = session.banner ?? "无法在线播放「\(title)」"
                    netdisk.message = text
                    showToast(text)
                }
            case .remux(let remotePath, let title, let url, let headers, let subtitlePaths):
                let item = library.upsertNetdisk(remotePath: remotePath, title: title, cachePath: nil, subtitleRefs: subtitlePaths)
                await session.openRemux(item, url: url, headers: headers, autoplay: true)
                if session.currentItem?.path == remotePath {
                    showToast("正在边转边播「\(title)」")
                } else {
                    let text = session.banner ?? "无法在线播放「\(title)」"
                    netdisk.message = text
                    showToast(text)
                }
            case .local(let remotePath, let title, let cachePath, let subtitlePaths):
                let item = library.upsertNetdisk(remotePath: remotePath, title: title, cachePath: cachePath, subtitleRefs: subtitlePaths)
                await session.open(item, autoplay: true)
                if session.currentItem?.path == remotePath {
                    showToast("正在播放缓存「\(title)」")
                } else {
                    showToast(session.banner ?? "无法播放「\(title)」")
                }
            case .blocked(let text):
                netdisk.message = text
                showToast(text)
            }
        }
    }

    func playNextAfterFinish() {
        guard library.settings.continuousPlay, let current = session.currentItem else { return }
        if current.source == .netdisk, !netdisk.playbackQueue.isEmpty {
            playNextNetdisk(after: current)
            return
        }
        let items = library.playlist
        guard items.count > 1, let index = items.firstIndex(where: { $0.id == current.id }) else {
            showToast("这一条已经播完")
            return
        }
        let next: MediaItem?
        if library.settings.shuffle {
            next = items.filter { $0.id != current.id }.randomElement()
        } else if index + 1 < items.count {
            next = items[index + 1]
        } else {
            next = nil
        }
        guard let next else {
            showToast("播放列表已结束")
            return
        }
        Task { await session.open(next, autoplay: true) }
    }

    private func playNextNetdisk(after current: MediaItem) {
        let items = netdisk.playbackQueue
        guard items.count > 1, let index = items.firstIndex(where: { $0.path == current.path }) else {
            showToast("这一条已经播完")
            return
        }
        let next: NetdiskFile?
        if library.settings.shuffle {
            next = items.filter { $0.path != current.path }.randomElement()
        } else if index + 1 < items.count {
            next = items[index + 1]
        } else {
            next = nil
        }
        guard let next else {
            showToast("播放列表已结束")
            return
        }
        playNetdisk(next)
    }

    func lookup(_ raw: String) {
        switch dictionary.lookup(raw) {
        case .opened(let word):
            showToast("已唤起欧陆词典查询 \(word)")
        case .notInstalled:
            showToast("未检测到欧陆词典。请先安装 Eudic，再双击单词查词。")
        case .invalid:
            showToast("这个词无法查询")
        }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    await self.importURLs([url])
                }
            }
        }
        return accepted
    }

    func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isTyping { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
                return event
            }
            return self.handleKey(event) ? nil : event
        }
    }

    private var isTyping: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49:
            session.togglePlay()
            return true
        case 123:
            session.previousSentence()
            if let banner = session.banner { showToast(banner) }
            return true
        case 124:
            session.nextSentence()
            if let banner = session.banner { showToast(banner) }
            return true
        case 126:
            showToast(session.adjustVolume(by: 0.05))
            return true
        case 125:
            showToast(session.adjustVolume(by: -0.05))
            return true
        default:
            break
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return false }
        if let digit = Int(key), (1...5).contains(digit) {
            session.setRate(PlaybackRate.numberKeys[digit - 1])
            showToast("倍速 \(PlaybackRate.display(session.rate))")
            return true
        }
        switch key {
        case "l":
            showToast(session.toggleSentenceLoop())
            return true
        case "b":
            showToast(session.cycleAB())
            return true
        case "s", "h":
            let next: SubtitleMode = session.subtitleMode == .hidden ? .bilingual : .hidden
            session.setSubtitleMode(next)
            showToast(next == .hidden ? "字幕已隐藏 · 盲听模式" : "字幕已显示")
            return true
        default:
            return false
        }
    }
}

public enum AppSection: String, CaseIterable, Identifiable {
    case player
    case playlist
    case netdisk
    case settings

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .player: return "播放"
        case .playlist: return "播放列表"
        case .netdisk: return "百度网盘"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .player: return "play.rectangle"
        case .playlist: return "list.bullet"
        case .netdisk: return "externaldrive"
        case .settings: return "gearshape"
        }
    }
}
