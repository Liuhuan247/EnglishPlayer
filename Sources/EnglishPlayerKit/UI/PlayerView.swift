import AppKit
import SwiftUI

struct PlayerScreen: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: PlaybackSession
    @State private var query = ""
    @State private var sentencesCollapsed = false
    @State private var volumeOpen = false
    @State private var followLatch = SentenceFollowLatch()
    @State private var followToken = 0
    @State private var acceptScrollEvents = false
    @State private var followTask: Task<Void, Never>?
    @State private var showChrome = true
    @State private var pointerOnControls = false
    @State private var pointerOnHandle = false
    @State private var chromeTask: Task<Void, Never>?

    private var filtered: [Sentence] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return session.sentences }
        return session.sentences.filter {
            $0.textEn.localizedCaseInsensitiveContains(text) || $0.textZh.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                stage
                if model.library.settings.waveformVisible {
                    waveformBar
                }
                if model.library.settings.statusBarVisible {
                    statusBar
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    bumpChrome()
                case .ended:
                    bumpChrome(after: 0.7)
                }
            }
            .onChange(of: session.isPlaying) { _, playing in
                if playing {
                    bumpChrome()
                } else {
                    revealChrome()
                }
            }
            .onChange(of: session.showsLoading) { _, loading in
                if loading { revealChrome() }
            }
            .onChange(of: volumeOpen) { _, open in
                if open {
                    revealChrome()
                } else {
                    bumpChrome()
                }
            }
            .onChange(of: session.currentItem?.id) { _, _ in
                revealChrome()
                bumpChrome()
            }
            if !sentencesCollapsed {
                sentenceSidebar
            }
        }
        .background(theme.background)
        .alert("无法查词", isPresented: Binding(
            get: { model.dictionaryAlert != nil },
            set: { if !$0 { model.dictionaryAlert = nil } }
        )) {
            Button("好") { model.dictionaryAlert = nil }
        } message: {
            Text(model.dictionaryAlert ?? "")
        }
    }

    private var subtitleSymbol: String {
        switch session.subtitleMode {
        case .bilingual: return "captions.bubble"
        case .english: return "textformat"
        case .chinese: return "character.textbox"
        case .hidden: return "eye.slash"
        }
    }

    private var sentenceSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
                TextField("搜索字幕内容", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                Button {
                    sentencesCollapsed = true
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("收起字幕列表")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(theme.searchFill, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            HStack {
                Text(session.sentences.isEmpty ? "字幕" : "字幕 · 共 \(session.sentences.count) 句")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text3)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            if session.isReadingEmbeddedSubtitles {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在读取片内字幕")
                        .font(.system(size: 13, weight: .semibold))
                    Text("画面可以先看。读完后句子会出现在这里，不用等整集下完。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text2)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if session.sentences.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("未找到字幕")
                        .font(.system(size: 13, weight: .semibold))
                    Text("把同名字幕放在媒体旁边，或手动指定 SRT / LRC。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text2)
                    Button("指定字幕…") { model.openSubtitlePanel() }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { sentence in
                                sentenceRow(sentence)
                                    .id(sentence.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                        .background {
                            UserScrollSpy {
                                noteUserScroll()
                            }
                        }
                    }
                    .onAppear { scrollToCurrent(proxy, animated: false) }
                    .onChange(of: session.currentIndex) { _, _ in
                        scrollToCurrent(proxy, animated: true)
                    }
                    .onChange(of: followToken) { _, _ in
                        scrollToCurrent(proxy, animated: true)
                    }
                    .onChange(of: query) { _, newValue in
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            followLatch.userChoseSentence()
                            followToken += 1
                        } else {
                            followTask?.cancel()
                            followLatch.userScrolled()
                        }
                    }
                }
            }
        }
        .frame(width: 500)
        .background(theme.sidebar)
        .overlay(alignment: .leading) { theme.separator.frame(width: 1) }
    }

    private func sentenceRow(_ sentence: Sentence) -> some View {
        let isCurrent = sentence.index == session.currentIndex
        return Button {
            followTask?.cancel()
            followLatch.userChoseSentence()
            model.session.jump(to: sentence.index)
        } label: {
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(isCurrent ? theme.accent : Color.clear)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("#\(sentence.displayIndex) · \(TimeFormat.clock(sentence.startTime + session.offset))")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.text3)
                    if !sentence.textEn.isEmpty {
                        Text(sentence.textEn)
                            .font(.system(size: 19, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? theme.accentDeep : theme.text)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !sentence.textZh.isEmpty {
                        Text(sentence.textZh)
                            .font(.system(size: 17))
                            .foregroundStyle(theme.text2)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(isCurrent ? theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help("跳转到这一句")
    }

    private func noteUserScroll() {
        guard acceptScrollEvents else { return }
        followLatch.userScrolled()
        followTask?.cancel()
        let due = followLatch.resumeAt ?? Date()
        followTask = Task { @MainActor in
            let wait = due.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            if followLatch.resumeIfDue() {
                followToken += 1
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard followLatch.following, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let id = session.currentSentence?.id else { return }
        acceptScrollEvents = false
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            acceptScrollEvents = true
        }
    }

    private var stage: some View {
        ZStack {
            theme.canvas
            if session.currentItem == nil {
                if !session.showsLoading {
                    emptyStage
                }
            } else if session.hasVideo {
                PlayerSurface(core: session.core)
            } else {
                audioArt
            }
            if session.currentItem != nil {
                VStack {
                    Spacer()
                    subtitleOverlay
                        .padding(.bottom, showChrome ? 108 : 22)
                        .padding(.horizontal, 28)
                        .animation(.easeInOut(duration: 0.22), value: showChrome)
                }
            }
            if session.statusText.hasPrefix("正在") && !session.showsLoading {
                Text(session.statusText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) { sentenceHandle }
        .overlay(alignment: .bottom) { playbackChrome }
    }

    /// 右缘的字幕列表把手和底部控制条共用同一套显隐：暂停时保持，播放后鼠标停住就收起。
    private var sentenceHandle: some View {
        Group {
            if session.currentItem != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sentencesCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: sentencesCollapsed ? "captions.bubble" : "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 72)
                        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help(sentencesCollapsed ? "展开字幕列表" : "收起字幕列表")
                .padding(.trailing, 12)
                .opacity(showChrome ? 1 : 0)
                .allowsHitTesting(showChrome)
                .animation(.easeInOut(duration: 0.22), value: showChrome)
                .onHover { inside in
                    pointerOnHandle = inside
                    if inside {
                        revealChrome()
                    } else {
                        bumpChrome()
                    }
                }
            }
        }
    }

    private var playbackChrome: some View {
        Group {
            if session.currentItem != nil || session.showsLoading {
                controlBar
                    .opacity(showChrome ? 1 : 0)
                    .offset(y: showChrome ? 0 : 18)
                    .allowsHitTesting(showChrome)
                    .animation(.easeInOut(duration: 0.22), value: showChrome)
                    .onHover { inside in
                        pointerOnControls = inside
                        if inside {
                            revealChrome()
                        } else {
                            bumpChrome()
                        }
                    }
            }
        }
    }

    private func revealChrome() {
        showChrome = true
        chromeTask?.cancel()
    }

    private func bumpChrome(after seconds: Double = 2.4) {
        showChrome = true
        chromeTask?.cancel()
        guard session.isPlaying, session.currentItem != nil, !session.showsLoading, !volumeOpen, !model.playlistOpen, !pointerOnControls, !pointerOnHandle else { return }
        chromeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard session.isPlaying, !session.showsLoading, !volumeOpen, !model.playlistOpen, !pointerOnControls, !pointerOnHandle else { return }
            showChrome = false
        }
    }

    private var emptyStage: some View {
        let resume = resumeItem
        let recent = recentItems
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("打开英语视频或音频")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text("也可以把文件直接拖进窗口。同目录的 SRT / LRC 会自动配对。")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                Button("打开文件…") { model.openFilesPanel() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .padding(.top, 2)
            }
            if let resume {
                VStack(alignment: .leading, spacing: 8) {
                    Text("继续播放")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    recentRow(resume, detail: "从 \(TimeFormat.clock(resume.lastPosition)) 继续")
                }
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    ForEach(recent) { item in
                        recentRow(item, detail: item.source == .netdisk ? "网盘" : "本地")
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var resumeItem: MediaItem? {
        guard let id = model.library.settings.lastMediaID,
              let item = model.library.media(id: id) else { return nil }
        if item.source == .local, !FileManager.default.fileExists(atPath: item.path) { return nil }
        return item
    }

    private var recentItems: [MediaItem] {
        let resumeID = resumeItem?.id
        return Array(model.library.recentMedia(limit: 8).filter { $0.id != resumeID }.prefix(5))
    }

    private func recentRow(_ item: MediaItem, detail: String) -> some View {
        Button { model.playSaved(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isAudio ? "waveform" : "film")
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var audioArt: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
            Text(session.currentItem?.title ?? "")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var subtitleOverlay: some View {
        let showEnglish = session.subtitleMode != .hidden && session.subtitleMode != .chinese
        let showChinese = session.subtitleMode == .bilingual || session.subtitleMode == .chinese
        let sentence = session.currentSentence
        let english = sentence?.textEn ?? ""
        let chinese = sentence?.textZh ?? ""
        let hasEnglish = showEnglish && !english.isEmpty
        let hasChinese = showChinese && !chinese.isEmpty
        return VStack(spacing: 4) {
            if hasEnglish {
                WordLine(
                    text: english,
                    fontSize: session.fontSize,
                    color: .white,
                    weight: .bold,
                    centered: true,
                    outlined: true,
                    onLookup: model.lookup
                )
            }
            if hasChinese {
                Text(chinese)
                    .font(.system(size: max(22, session.fontSize * 0.78), weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.2))
                    .captionOutline(true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity)
        .opacity(session.subtitleMode == .hidden ? 0 : 1)
    }

    private var waveformBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("当前句波形")
                    .font(.system(size: 12, weight: .semibold))
                Text(session.waveformNote ?? "点击波形定位")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3)
                    .lineLimit(2)
            }
            .frame(width: 108, alignment: .leading)
            WaveformCanvas(peaks: session.waveform, fraction: session.waveformFraction) { ratio in
                session.seekInSentence(ratio)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(theme.background)
        .overlay(alignment: .top) { theme.separator.frame(height: 1) }
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(TimeFormat.clock(session.currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.text2)
                    .frame(width: 64, alignment: .leading)
                ProgressSlider(
                    fraction: session.duration > 0 ? session.currentTime / session.duration : 0,
                    sentence: sentenceFraction,
                    markA: markFraction(session.abStart),
                    markB: markFraction(session.abEnd),
                    onSeek: { session.seekFraction($0) },
                    onMoveA: { session.moveLoopBound(isStart: true, to: $0) },
                    onMoveB: { session.moveLoopBound(isStart: false, to: $0) }
                )
                Text(TimeFormat.clock(session.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.text2)
                    .frame(width: 64, alignment: .trailing)
            }
            ZStack {
                HStack(spacing: 8) {
                    IconButton(systemName: "repeat.1", help: "单句循环", active: session.loopMode == .sentence) {
                        model.showToast(session.toggleSentenceLoop())
                    }
                    IconButton(systemName: "arrow.left.arrow.right", help: "按句 A-B。点一下记起点句，再点记结束句。进度条上可拖动", active: session.loopMode == .ab || session.abStart != nil) {
                        model.showToast(session.cycleAB())
                    }
                    IconButton(systemName: subtitleSymbol, help: "画面字幕：\(session.subtitleMode.title)。不改变右侧列表", active: session.subtitleMode == .hidden) {
                        cycleSubtitleMode()
                    }
                    IconButton(
                        systemName: "waveform",
                        help: model.library.settings.waveformVisible ? "隐藏波形" : "显示波形",
                        active: model.library.settings.waveformVisible
                    ) {
                        let visible = !model.library.settings.waveformVisible
                        model.library.setWaveformVisible(visible)
                        model.showToast(visible ? "波形已显示" : "波形已隐藏")
                    }
                    offsetControl
                    Spacer(minLength: 0)
                    speedMenu
                    volumeButton
                    playlistButton
                }
                HStack(spacing: 8) {
                    IconButton(systemName: "backward.end.fill", help: "上一句") { session.previousSentence() }
                    IconButton(
                        systemName: session.isPlaying ? "pause.fill" : "play.fill",
                        help: session.showsLoading ? "正在加载" : "播放 / 暂停",
                        prominent: true,
                        loading: session.showsLoading
                    ) {
                        session.togglePlay()
                    }
                    IconButton(systemName: "forward.end.fill", help: "下一句") { session.nextSentence() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(theme.surface)
        .overlay(alignment: .top) { theme.separator.frame(height: 1) }
        .shadow(color: .black.opacity(0.28), radius: 14, y: -4)
    }

    private var playlistButton: some View {
        IconButton(systemName: "list.bullet", help: "播放列表", active: model.playlistOpen) {
            model.playlistOpen.toggle()
            if model.playlistOpen { revealChrome() }
        }
        .popover(isPresented: Binding(
            get: { model.playlistOpen },
            set: { model.playlistOpen = $0 }
        ), arrowEdge: .bottom) {
            PlaylistScreen(compact: true)
                .environmentObject(model)
                .environmentObject(session)
                .environmentObject(model.library)
                .environmentObject(model.netdisk)
                .environment(\.theme, theme)
                .frame(width: 520, height: 460)
        }
        .onChange(of: model.playlistOpen) { _, open in
            if open { revealChrome() }
        }
    }

    private var volumeButton: some View {
        IconButton(
            systemName: session.volume < 0.02 ? "speaker.slash" : "speaker.wave.2",
            help: "音量",
            active: volumeOpen
        ) {
            volumeOpen.toggle()
        }
        .popover(isPresented: $volumeOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("音量 \(Int((session.volume * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium))
                Slider(value: Binding(
                    get: { Double(session.volume) },
                    set: { value in
                        session.volume = Float(value)
                        session.core.volume = session.volume
                    }
                ), in: 0...1)
                .frame(width: 160)
            }
            .padding(12)
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PlaybackRate.all, id: \.self) { value in
                Button {
                    session.setRate(value)
                    model.showToast("倍速已设为 \(PlaybackRate.display(value))")
                } label: {
                    if abs(session.rate - value) < 0.01 {
                        Label(PlaybackRate.display(value), systemImage: "checkmark")
                    } else {
                        Text(PlaybackRate.display(value))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 13, weight: .semibold))
                Text(PlaybackRate.display(session.rate))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(abs(session.rate - 1) > 0.01 ? theme.accent : theme.icon)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(abs(session.rate - 1) > 0.01 ? theme.accentSoft : Color.clear)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("播放速度，当前 \(PlaybackRate.display(session.rate))")
        .accessibilityLabel("播放速度")
    }

    private var sentenceFraction: (start: Double, end: Double)? {
        guard let sentence = session.currentSentence, session.duration > 0 else { return nil }
        let start = (sentence.startTime + session.offset) / session.duration
        let end = (sentence.endTime + session.offset) / session.duration
        return (min(1, max(0, start)), min(1, max(0, end)))
    }

    private func markFraction(_ time: Double?) -> Double? {
        guard let time, session.duration > 0 else { return nil }
        return min(1, max(0, time / session.duration))
    }

    private var offsetControl: some View {
        HStack(spacing: 2) {
            Button("前") {
                session.nudgeOffset(by: -0.1)
                model.showToast("字幕提前到 \(TimeFormat.milliseconds(session.offset))")
            }
            .help("字幕提前 0.1 秒")
            Text(TimeFormat.milliseconds(session.offset))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.text2)
                .frame(width: 62)
            Button("后") {
                session.nudgeOffset(by: 0.1)
                model.showToast("字幕延后到 \(TimeFormat.milliseconds(session.offset))")
            }
            .help("字幕延后 0.1 秒")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.icon)
    }

    private func cycleSubtitleMode() {
        let order = SubtitleMode.allCases
        guard let index = order.firstIndex(of: session.subtitleMode) else { return }
        let next = order[(index + 1) % order.count]
        session.setSubtitleMode(next)
        model.showToast(next == .hidden ? "画面字幕已隐藏" : "画面字幕：\(next.title)")
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(session.currentItem == nil ? theme.text3 : theme.green).frame(width: 7, height: 7)
            Text(session.statusText)
                .lineLimit(1)
            Spacer()
            Text(PlaybackRate.display(session.rate))
                .foregroundStyle(theme.text3)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(theme.text2)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(theme.sidebar)
        .overlay(alignment: .top) { theme.separator.frame(height: 1) }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let core: MediaCoreProtocol

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.onLayout = { core.layoutPreview() }
        core.attachPreview(to: view)
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        core.attachPreview(to: nsView)
        core.layoutPreview()
    }
}

final class PlayerHostView: NSView {
    var onLayout: (() -> Void)?

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

struct WaveformCanvas: View {
    var peaks: [Float]
    var fraction: Double
    var onSeek: (Double) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard peaks.count > 1 else { return }
                let shape = envelope(peaks: peaks, size: size)
                context.fill(shape, with: .color(theme.waveIdle))
                let played = size.width * CGFloat(min(1, max(0, fraction)))
                context.drawLayer { layer in
                    var clip = Path()
                    clip.addRect(CGRect(x: 0, y: 0, width: played, height: size.height))
                    layer.clip(to: clip)
                    layer.fill(shape, with: .color(theme.accent))
                }
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height / 2))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(baseline, with: .color(theme.separator), lineWidth: 1)
                var line = Path()
                line.move(to: CGPoint(x: played, y: 2))
                line.addLine(to: CGPoint(x: played, y: size.height - 2))
                context.stroke(line, with: .color(theme.accent), lineWidth: 1.5)
                let knob = Path(ellipseIn: CGRect(x: played - 4, y: size.height / 2 - 4, width: 8, height: 8))
                context.fill(knob, with: .color(theme.knob))
                context.stroke(knob, with: .color(theme.accent), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let ratio = value.location.x / max(geo.size.width, 1)
                onSeek(min(1, max(0, ratio)))
            })
        }
        .frame(height: 54)
        .help("点击波形，定位到这一句里的对应位置")
    }

    /// 上下对称的连续包络，而不是一根根竖条。
    private func envelope(peaks: [Float], size: CGSize) -> Path {
        let mid = size.height / 2
        let usable = mid - 4
        let step = size.width / CGFloat(max(peaks.count - 1, 1))
        func point(_ index: Int, upper: Bool) -> CGPoint {
            let amp = CGFloat(min(1, max(0, peaks[index]))) * usable
            return CGPoint(x: CGFloat(index) * step, y: upper ? mid - amp : mid + amp)
        }
        var path = Path()
        path.move(to: point(0, upper: true))
        if peaks.count > 1 {
            for index in 1..<peaks.count {
                let previous = point(index - 1, upper: true)
                let current = point(index, upper: true)
                path.addQuadCurve(to: current, control: CGPoint(x: (previous.x + current.x) / 2, y: previous.y))
            }
            path.addLine(to: point(peaks.count - 1, upper: false))
            for index in stride(from: peaks.count - 2, through: 0, by: -1) {
                let previous = point(index + 1, upper: false)
                let current = point(index, upper: false)
                path.addQuadCurve(to: current, control: CGPoint(x: (previous.x + current.x) / 2, y: previous.y))
            }
        }
        path.closeSubpath()
        return path
    }
}

struct ProgressSlider: View {
    var fraction: Double
    var sentence: (start: Double, end: Double)?
    var markA: Double?
    var markB: Double?
    var onSeek: (Double) -> Void
    var onMoveA: (Double) -> Void
    var onMoveB: (Double) -> Void

    @Environment(\.theme) private var theme
    @State private var drag: DragTarget?

    private enum DragTarget {
        case seek
        case a
        case b
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let played = width * CGFloat(min(1, max(0, fraction)))
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(theme.waveIdle)
                    .frame(height: 4)
                    .offset(y: 16)
                if let sentence {
                    span(sentence.start, sentence.end, width: width)
                        .fill(theme.accent.opacity(0.28))
                }
                if let markA, let markB {
                    span(markA, markB, width: width)
                        .fill(theme.orange.opacity(0.85))
                }
                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(0, played), height: 4)
                    .offset(y: 16)
                Circle()
                    .fill(theme.knob)
                    .overlay(Circle().stroke(theme.separator))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    .offset(x: min(max(0, played - 7), width - 14), y: 11)
                if let markA {
                    marker("A", fraction: markA, width: width)
                }
                if let markB {
                    marker("B", fraction: markB, width: width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let ratio = min(1, max(0, value.location.x / width))
                if drag == nil {
                    drag = target(at: value.startLocation.x, width: width)
                }
                switch drag {
                case .a: onMoveA(ratio)
                case .b: onMoveB(ratio)
                default: onSeek(ratio)
                }
            }.onEnded { _ in
                drag = nil
            })
        }
        .frame(height: 28)
        .help("拖动进度。当前句会高亮；A、B 两点可以拖动")
    }

    private func span(_ start: Double, _ end: Double, width: CGFloat) -> some Shape {
        let left = width * CGFloat(min(start, end))
        let right = width * CGFloat(max(start, end))
        return Capsule().path(in: CGRect(x: left, y: 16, width: max(2, right - left), height: 4))
    }

    private func marker(_ label: String, fraction: Double, width: CGFloat) -> some View {
        let x = width * CGFloat(min(1, max(0, fraction)))
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.orange)
            .position(x: min(max(8, x), width - 8), y: 6)
    }

    private func target(at x: CGFloat, width: CGFloat) -> DragTarget {
        func near(_ fraction: Double?) -> Bool {
            guard let fraction else { return false }
            return abs(x - width * CGFloat(fraction)) < 12
        }
        if near(markA), !near(markB) || abs(x - width * CGFloat(markA ?? 0)) <= abs(x - width * CGFloat(markB ?? 0)) {
            if near(markA) { return .a }
        }
        if near(markB) { return .b }
        return .seek
    }
}

/// 监听列表滚动。程序触发的滚动会暂时关掉回调，避免被当成用户操作。
struct UserScrollSpy: NSViewRepresentable {
    var onScroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> SpyView {
        let view = SpyView()
        view.onAttach = { scroll in
            context.coordinator.attach(scroll)
        }
        return view
    }

    func updateNSView(_ nsView: SpyView, context: Context) {
        context.coordinator.onScroll = onScroll
        nsView.onAttach = { scroll in
            context.coordinator.attach(scroll)
        }
    }

    final class Coordinator {
        var onScroll: () -> Void
        private var observer: NSObjectProtocol?

        init(onScroll: @escaping () -> Void) {
            self.onScroll = onScroll
        }

        func attach(_ scroll: NSScrollView) {
            guard observer == nil else { return }
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let event = NSApp.currentEvent else { return }
                switch event.type {
                case .scrollWheel, .leftMouseDragged, .magnify:
                    self?.onScroll()
                default:
                    break
                }
            }
        }
    }
}

final class SpyView: NSView {
    var onAttach: ((NSScrollView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let scroll = self.enclosingScrollView else { return }
            self.onAttach?(scroll)
        }
    }
}
