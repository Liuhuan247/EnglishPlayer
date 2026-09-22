import Combine
import Foundation

@MainActor
final class PlaybackSession: ObservableObject {
    @Published var currentItem: MediaItem?
    @Published var sentences: [Sentence] = []
    @Published var currentIndex = 0
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Double = 1
    @Published var volume: Float = 1
    @Published var loopMode: LoopMode = .off
    @Published var subtitleMode: SubtitleMode = .bilingual
    @Published var fontSize: Double = 23
    @Published var offset: Double = 0
    @Published var waveform: [Float] = []
    @Published var waveformFraction: Double = 0
    @Published var waveformNote: String?
    @Published var statusText = "拖入或打开英语视频、音频，开始逐句精听"
    @Published var banner: String?
    @Published var hasVideo = false

    var onFinished: (() -> Void)?
    let core: MediaCoreProtocol

    private let library: LibraryService
    private let waveforms: WaveformService
    private var engine = SentenceEngine()
    private var seekTarget: Double?
    private var seekStarted = Date.distantPast
    private var didFinish = false
    private var waveformTask: Task<Void, Never>?
    private var lastPersist = Date.distantPast

    init(core: MediaCoreProtocol, library: LibraryService, waveforms: WaveformService) {
        self.core = core
        self.library = library
        self.waveforms = waveforms
        rate = library.settings.defaultRate
        subtitleMode = library.settings.subtitleMode
        fontSize = library.settings.fontSize
        offset = library.settings.subtitleOffset
        volume = 1
        core.setRate(rate)
        core.setPitchPreservation(library.settings.preservePitch)
        core.statusHandler = { [weak self] text in
            self?.statusText = text
        }
        core.setTimeObserver { [weak self] time in
            Task { @MainActor in
                self?.handleTick(time)
            }
        }
    }

    var currentSentence: Sentence? { engine.current }

    func open(_ item: MediaItem, autoplay: Bool) async {
        guard let url = item.playableURL else {
            banner = PlayerError.fileMissing.localizedDescription
            statusText = banner ?? ""
            return
        }
        await present(item, autoplay: autoplay) {
            try await self.core.open(url: url)
        }
    }

    func openRemote(_ item: MediaItem, url: URL, headers: [String: String], autoplay: Bool) async {
        await present(item, autoplay: autoplay) {
            try await self.core.openRemote(url: url, headers: headers)
        }
    }

    func openRemux(_ item: MediaItem, url: URL, headers: [String: String], autoplay: Bool) async {
        await present(item, autoplay: autoplay) {
            try await self.core.openRemux(url: url, headers: headers)
        }
    }

    private func present(_ item: MediaItem, autoplay: Bool, loader: () async throws -> Void) async {
        persist()
        waveformTask?.cancel()
        banner = nil
        do {
            try await loader()
        } catch let error as PlayerError {
            if case .streamUnsupported = error {
                banner = PlayerError.streamUnsupported(item.title).errorDescription
            } else {
                banner = error.errorDescription
            }
            statusText = banner ?? ""
            isPlaying = false
            return
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? "无法播放这个文件。"
            statusText = banner ?? ""
            isPlaying = false
            return
        }

        duration = core.duration
        hasVideo = core.hasVideo
        var fresh = item
        fresh.duration = core.duration
        fresh.updatedAt = Date()
        let loaded = SubtitleEngine.load(
            mediaPath: item.path,
            localPath: item.cachePath ?? item.path,
            explicitRefs: item.subtitleRefs
        )
        let tagged = tag(loaded.sentences, mediaID: item.id)
        library.replaceSentences(mediaID: item.id, tagged)
        if !loaded.refs.isEmpty {
            fresh.subtitleRefs = loaded.refs
        }
        engine.load(tagged)
        sentences = tagged
        currentIndex = 0
        loopMode = .off
        offset = fresh.subtitleOffset
        didFinish = false
        banner = loaded.warning

        let resume = library.settings.autoResume ? fresh.lastPosition : 0
        if resume > 0.4, resume < duration - 0.4 {
            await core.seek(to: resume)
            currentTime = resume
            if let index = engine.containingIndex(at: resume, offset: offset) {
                _ = engine.select(index: index)
                currentIndex = index
            }
        } else {
            currentTime = 0
        }
        rate = library.settings.defaultRate
        core.setRate(rate)
        library.save(fresh)
        library.remember(mediaID: fresh.id)
        currentItem = library.media(id: fresh.id) ?? fresh
        refreshWaveform()
        statusText = statusLine()
        if autoplay {
            core.play()
            isPlaying = true
        } else {
            core.pause()
            isPlaying = false
        }
    }

    func useSubtitle(at url: URL) {
        guard var item = currentItem else {
            banner = "请先打开一个音视频，再指定字幕。"
            return
        }
        item.subtitleRefs = [url.path]
        let loaded = SubtitleEngine.load(mediaPath: item.path, localPath: item.cachePath ?? item.path, explicitRefs: item.subtitleRefs)
        let tagged = tag(loaded.sentences, mediaID: item.id)
        guard !tagged.isEmpty else {
            banner = loaded.warning ?? "这个字幕文件没有可用的句子。"
            return
        }
        library.replaceSentences(mediaID: item.id, tagged)
        item.subtitleRefs = loaded.refs.isEmpty ? [url.path] : loaded.refs
        library.save(item)
        currentItem = item
        engine.load(tagged)
        sentences = tagged
        currentIndex = engine.containingIndex(at: currentTime, offset: offset) ?? 0
        _ = engine.select(index: currentIndex)
        banner = "已加载字幕 \(url.lastPathComponent)"
        refreshWaveform()
        statusText = statusLine()
    }

    func togglePlay() {
        if core.isPlaying {
            core.pause()
            isPlaying = false
            persist()
        } else {
            didFinish = false
            core.play()
            isPlaying = true
        }
        statusText = statusLine()
    }

    func jump(to index: Int) {
        guard let sentence = engine.select(index: index) else { return }
        currentIndex = index
        waveformFraction = 0
        didFinish = false
        refreshWaveform()
        requestSeek(max(0, sentence.startTime + offset))
        core.play()
        isPlaying = true
        statusText = statusLine()
    }

    func previousSentence() {
        guard !sentences.isEmpty else {
            banner = "还没有字幕，无法按句跳转。"
            return
        }
        guard engine.previous() != nil else { return }
        jump(to: engine.currentIndex)
    }

    func nextSentence() {
        guard !sentences.isEmpty else {
            banner = "还没有字幕，无法按句跳转。"
            return
        }
        guard engine.next() != nil else { return }
        jump(to: engine.currentIndex)
    }

    func seekFraction(_ fraction: Double) {
        guard duration > 0 else { return }
        let target = duration * min(1, max(0, fraction))
        if let index = engine.containingIndex(at: target, offset: offset) {
            _ = engine.select(index: index)
            currentIndex = index
            refreshWaveform()
        }
        requestSeek(target)
    }

    func seekInSentence(_ ratio: Double) {
        guard let sentence = engine.current else { return }
        let start = sentence.startTime + offset
        let end = sentence.endTime + offset
        let target = start + (end - start) * min(1, max(0, ratio))
        waveformFraction = min(1, max(0, ratio))
        requestSeek(max(0, target))
    }

    func setRate(_ value: Double) {
        rate = PlaybackRate.stepped(value)
        core.setRate(rate)
        library.setDefaultRate(rate)
        statusText = statusLine()
    }

    func toggleSentenceLoop() -> String {
        if loopMode == .sentence {
            loopMode = .off
            engine.loopMode = .off
        } else {
            loopMode = .sentence
            engine.loopMode = .sentence
            engine.abStart = nil
            engine.abEnd = nil
        }
        statusText = statusLine()
        return loopMode == .sentence ? "单句循环：开" : "单句循环：关"
    }

    func cycleAB() -> String {
        engine.loopMode = loopMode
        let message = engine.cycleAB(at: currentTime)
        loopMode = engine.loopMode
        statusText = statusLine()
        return message
    }

    func setSubtitleMode(_ mode: SubtitleMode) {
        subtitleMode = mode
        engine.blind = mode == .hidden
        library.setSubtitleMode(mode)
        statusText = statusLine()
    }

    func setFontSize(_ size: Double) {
        let clamped = min(32, max(18, size))
        fontSize = clamped
        library.setFontSize(clamped)
    }

    func setOffset(_ seconds: Double) {
        offset = seconds
        if var item = currentItem {
            item.subtitleOffset = seconds
            currentItem = item
            library.save(item)
        }
        library.setSubtitleOffset(seconds)
        refreshWaveform()
    }

    func adjustVolume(by delta: Float) -> String {
        volume = min(1, max(0, volume + delta))
        core.volume = volume
        return "音量 \(Int((volume * 100).rounded()))%"
    }

    func applyPitchPreservation(_ enabled: Bool) {
        core.setPitchPreservation(enabled)
        library.setPreservePitch(enabled)
    }

    func persist() {
        guard var item = currentItem else { return }
        let position = currentTime
        item.lastPosition = position
        item.duration = duration
        item.subtitleOffset = offset
        item.updatedAt = Date()
        currentItem = item
        library.save(item)
        library.remember(mediaID: item.id)
        library.savePlayback(mediaID: item.id, position: position, rate: rate, loopMode: loopMode)
        lastPersist = Date()
    }

    func handleTick(_ time: Double) {
        currentTime = time
        if let target = seekTarget {
            let arrived = abs(time - target) < 0.12
            let timedOut = Date().timeIntervalSince(seekStarted) > 1.2
            if !arrived && !timedOut { return }
            seekTarget = nil
        }
        guard currentItem != nil else { return }
        switch engine.action(at: time, offset: offset) {
        case .follow(let index, let fraction):
            let changed = index != currentIndex
            _ = engine.select(index: index)
            currentIndex = index
            waveformFraction = fraction
            isPlaying = core.isPlaying
            if changed {
                refreshWaveform()
                statusText = statusLine()
            }
            maybePersist()
        case .seek(let target, let index):
            _ = engine.select(index: index)
            currentIndex = index
            waveformFraction = 0
            requestSeek(target)
        case .ended:
            waveformFraction = 1
            guard !didFinish else { return }
            didFinish = true
            core.pause()
            isPlaying = false
            persist()
            onFinished?()
        case .idle:
            isPlaying = core.isPlaying
            maybePersist()
        }
    }

    private func requestSeek(_ time: Double) {
        let upper = duration > 0 ? duration : time
        let target = min(max(0, time), upper)
        seekTarget = target
        seekStarted = Date()
        didFinish = false
        currentTime = target
        Task { await self.core.seek(to: target) }
    }

    private func refreshWaveform() {
        guard let item = currentItem, let sentence = engine.current else {
            waveform = []
            waveformNote = sentences.isEmpty ? "加载字幕后会显示当前句波形" : nil
            return
        }
        guard let url = core.openedURL ?? item.playableURL else {
            waveform = []
            waveformNote = sentences.isEmpty ? "加载字幕后会显示当前句波形" : nil
            return
        }
        if url.pathExtension.lowercased() == "m3u8" {
            waveform = []
            waveformNote = "边转边播时暂不生成波形"
            return
        }
        if !url.isFileURL {
            waveform = []
            waveformNote = "在线播放暂不生成波形"
            return
        }
        let variant = String(Int((offset * 1000).rounded()))
        if let cached = waveforms.cachedPeaks(mediaID: item.id, index: sentence.index, variant: variant) {
            waveform = cached
            waveformNote = nil
            return
        }
        waveformNote = "正在提取当前句波形…"
        waveformTask?.cancel()
        let index = sentence.index
        let start = sentence.startTime + offset
        let end = sentence.endTime + offset
        waveformTask = Task { [weak self] in
            guard let self else { return }
            do {
                let peaks = try await self.waveforms.peaks(
                    mediaID: item.id,
                    index: index,
                    variant: variant,
                    url: url,
                    start: start,
                    end: end
                )
                guard !Task.isCancelled, self.currentIndex == index else { return }
                self.waveform = peaks
                self.waveformNote = nil
            } catch PlayerError.noAudioTrack {
                self.waveform = []
                self.waveformNote = PlayerError.noAudioTrack.localizedDescription
            } catch {
                self.waveform = []
                self.waveformNote = (error as? LocalizedError)?.errorDescription ?? PlayerError.waveformFailed("未知原因").localizedDescription
            }
        }
    }

    private func maybePersist() {
        guard Date().timeIntervalSince(lastPersist) > 2 else { return }
        persist()
    }

    private func statusLine() -> String {
        let source: String
        if currentItem?.source == .netdisk {
            source = currentItem?.cachePath == nil ? "网盘在线" : "网盘缓存"
        } else if currentItem != nil {
            source = currentItem?.isAudio == true ? "本地音频" : "本地视频"
        } else {
            source = "尚未打开文件"
        }
        let subtitle: String
        if sentences.isEmpty {
            subtitle = "未找到字幕"
        } else {
            subtitle = "字幕 \(sentences.count) 句"
        }
        let loop: String
        switch loopMode {
        case .off: loop = "循环关"
        case .sentence: loop = "单句循环"
        case .ab: loop = "A-B 循环"
        }
        let position = TimeFormat.clock(currentTime)
        return "\(subtitle) · \(source) · 断点 \(position) · \(PlaybackRate.display(rate)) · \(loop)"
    }

    private func tag(_ sentences: [Sentence], mediaID: String) -> [Sentence] {
        sentences.enumerated().map { index, sentence in
            var copy = sentence
            copy.mediaID = mediaID
            copy.index = index
            copy.id = "\(mediaID)#\(index)"
            return copy
        }
    }
}
