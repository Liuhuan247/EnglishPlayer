import SwiftUI

struct SettingsScreen: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var session: PlaybackSession
    @State private var cacheUsed: Int64 = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                group("外观") {
                    row("主题", detail: "跟随系统，或固定浅色 / 深色") {
                        Picker("主题", selection: Binding(
                            get: { library.settings.appearance },
                            set: { library.setAppearance($0) }
                        )) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                        .labelsHidden()
                    }
                    row("底部信息栏", detail: "显示当前文件状态和倍速，默认关闭") {
                        Toggle("", isOn: Binding(
                            get: { library.settings.statusBarVisible },
                            set: { library.setStatusBarVisible($0) }
                        ))
                        .labelsHidden()
                        .tint(theme.accent)
                    }
                }
                group("字幕") {
                    row("显示模式", detail: "双语 / 仅英文 / 仅中文 / 隐藏（盲听）") {
                        Picker("显示模式", selection: Binding(
                            get: { session.subtitleMode },
                            set: { session.setSubtitleMode($0) }
                        )) {
                            ForEach(SubtitleMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                        .labelsHidden()
                    }
                    row("字号", detail: "主字幕 18–32 pt") {
                        HStack(spacing: 8) {
                            Button("−") { session.setFontSize(session.fontSize - 1) }
                            Text("\(Int(session.fontSize)) pt")
                                .frame(width: 52)
                            Button("+") { session.setFontSize(session.fontSize + 1) }
                        }
                    }
                    row("时间偏移", detail: "字幕与声音不同步时的整体校正") {
                        HStack(spacing: 10) {
                            Text(TimeFormat.milliseconds(session.offset))
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 72, alignment: .trailing)
                            Slider(value: Binding(
                                get: { session.offset },
                                set: { session.setOffset($0) }
                            ), in: -5...5)
                            .frame(width: 180)
                            Button("归零") { session.setOffset(0) }
                        }
                    }
                }
                group("播放") {
                    row("自动断点续播", detail: "重新打开文件时回到上次位置") {
                        Toggle("", isOn: Binding(
                            get: { library.settings.autoResume },
                            set: { library.setAutoResume($0) }
                        ))
                        .labelsHidden()
                        .tint(theme.accent)
                    }
                    row("默认倍速", detail: "新文件打开时的播放速度") {
                        Picker("默认倍速", selection: Binding(
                            get: { PlaybackRate.stepped(library.settings.defaultRate) },
                            set: { session.setRate($0) }
                        )) {
                            ForEach([0.75, 1.0, 1.25, 1.5], id: \.self) { rate in
                                Text(PlaybackRate.display(rate)).tag(rate)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        .labelsHidden()
                    }
                }
                group("百度网盘缓存") {
                    row("缓存目录", detail: cachePath) {
                        Button("更改…") { model.chooseCacheDirectory() }
                    }
                    row("已用空间", detail: "上限 \(ByteFormat.string(library.settings.cacheLimitBytes))") {
                        HStack(spacing: 10) {
                            ProgressView(value: cacheFraction)
                                .tint(theme.orange)
                                .frame(width: 160)
                            Text("\(Int(cacheFraction * 100))%")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.text2)
                            Button("清理缓存") {
                                model.clearCache()
                                refreshUsage()
                            }
                        }
                    }
                    row("缓存上限", detail: "超出后会从最旧的缓存开始清理") {
                        Picker("缓存上限", selection: Binding(
                            get: { library.settings.cacheLimitBytes },
                            set: { library.setCacheLimit($0) }
                        )) {
                            Text("5 GB").tag(Int64(5) * 1024 * 1024 * 1024)
                            Text("10 GB").tag(Int64(10) * 1024 * 1024 * 1024)
                            Text("20 GB").tag(Int64(20) * 1024 * 1024 * 1024)
                            Text("50 GB").tag(Int64(50) * 1024 * 1024 * 1024)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
                group("快捷键") {
                    shortcut("播放 / 暂停", keys: ["Space"])
                    shortcut("上一句 / 下一句", keys: ["←", "→"])
                    shortcut("单句循环 / A-B 循环", keys: ["L", "B"])
                    shortcut("倍速 0.5 / 0.75 / 1.0 / 1.5 / 2.0", keys: ["1", "2", "3", "4", "5"])
                    shortcut("隐藏字幕（盲听）", keys: ["S", "H"])
                    shortcut("音量", keys: ["↑", "↓"])
                }
            }
            .padding(.vertical, 6)
        }
        .background(theme.background)
        .onAppear(perform: refreshUsage)
    }

    private var cachePath: String {
        library.settings.cacheDirectory ?? model.cache.directory.path
    }

    private var cacheFraction: Double {
        guard library.settings.cacheLimitBytes > 0 else { return 0 }
        return min(1, Double(cacheUsed) / Double(library.settings.cacheLimitBytes))
    }

    private func refreshUsage() {
        cacheUsed = model.cache.totalSize()
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.bottom, 4)
            content()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { theme.separator.frame(height: 1) }
    }

    private func row<Accessory: View>(_ title: String, detail: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            Spacer()
            accessory()
        }
        .padding(.vertical, 6)
    }

    private func shortcut(_ name: String, keys: [String]) -> some View {
        HStack {
            Text(name).font(.system(size: 12.5))
            Spacer()
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.sidebar, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.separator))
            }
        }
        .padding(.vertical, 5)
    }
}

public struct SettingsWindow: View {
    @Environment(\.colorScheme) private var systemScheme
    @EnvironmentObject private var model: AppModel

    public init() {}

    private var palette: ThemePalette {
        ThemePalette.resolve(model.library.settings.appearance, system: systemScheme)
    }

    public var body: some View {
        SettingsScreen()
            .environmentObject(model.session)
            .environmentObject(model.library)
            .background(palette.background)
            .foregroundStyle(palette.text)
            .tint(palette.accent)
            .environment(\.theme, palette)
            .preferredColorScheme(model.library.settings.appearance.preferred)
            .frame(minWidth: 640, minHeight: 520)
    }
}

public struct RootView: View {
    @Environment(\.colorScheme) private var systemScheme
    @EnvironmentObject private var model: AppModel

    public init() {}

    private var palette: ThemePalette {
        ThemePalette.resolve(model.library.settings.appearance, system: systemScheme)
    }

    public var body: some View {
        PlayerScreen()
            .environmentObject(model.session)
            .environmentObject(model.library)
            .environmentObject(model.netdisk)
            .frame(minWidth: 1080, minHeight: 680)
            .background(palette.background)
            .foregroundStyle(palette.text)
            .tint(palette.accent)
            .environment(\.theme, palette)
            .preferredColorScheme(model.library.settings.appearance.preferred)
            .overlay(alignment: .bottom) { toast }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: model.acceptDrop)
            .task { await model.restoreIfNeeded() }
            .onReceive(model.session.$banner.compactMap { $0 }) { banner in
                if !banner.isEmpty { model.showToast(banner) }
            }
    }

    @ViewBuilder
    private var toast: some View {
        if let text = model.toast {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(palette.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.text.opacity(0.92), in: RoundedRectangle(cornerRadius: 9))
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

public struct PlayerCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开…") { model.openFilesPanel() }
                .keyboardShortcut("o")
            Button("打开字幕…") { model.openSubtitlePanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("播放列表") { openWindow(id: "playlist") }
            Button("百度网盘") { openWindow(id: "netdisk") }
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { openWindow(id: "settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("播放") {
            Button("播放 / 暂停") { model.session.togglePlay() }
            Button("上一句") { model.session.previousSentence() }
            Button("下一句") { model.session.nextSentence() }
            Button("单句循环") { _ = model.session.toggleSentenceLoop() }
            Button("A-B 循环") { _ = model.session.cycleAB() }
            Divider()
            Button("0.5x") { model.session.setRate(0.5) }
            Button("0.75x") { model.session.setRate(0.75) }
            Button("1.0x") { model.session.setRate(1) }
            Button("1.25x") { model.session.setRate(1.25) }
            Button("1.5x") { model.session.setRate(1.5) }
            Button("1.75x") { model.session.setRate(1.75) }
            Button("2.0x") { model.session.setRate(2) }
        }
    }
}
