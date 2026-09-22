import AppKit
import SwiftUI

struct PlaylistScreen: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var session: PlaybackSession
    @EnvironmentObject private var netdisk: NetdiskService

    private var showingNetdisk: Bool {
        session.currentItem?.source == .netdisk && !netdisk.playbackQueue.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingNetdisk {
                netdiskQueue
            } else {
                localQueue
            }
        }
        .background(theme.background)
    }

    private var netdiskQueue: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("网盘目录（\(netdisk.playbackQueue.count)）")
                    .font(.system(size: 13.5, weight: .semibold))
                chip("连续播放", system: "play.fill", on: library.settings.continuousPlay) {
                    library.setContinuousPlay(!library.settings.continuousPlay)
                    model.showToast(library.settings.continuousPlay ? "连续播放：开" : "连续播放：关")
                }
                Spacer()
                Text(netdisk.playbackDirectory)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { theme.separator.frame(height: 1) }

            List {
                ForEach(Array(netdisk.playbackQueue.enumerated()), id: \.element.path) { index, file in
                    netdiskRow(index: index, file: file)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(theme.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func netdiskRow(index: Int, file: NetdiskFile) -> some View {
        let playing = file.path == session.currentItem?.path
        return HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text3)
                .frame(width: 20, alignment: .trailing)
            Image(systemName: playing ? "play.fill" : (file.isPlayable && MediaKind.isAudio(file.name) ? "waveform" : "film"))
                .frame(width: 34, height: 34)
                .background(MediaKind.isAudio(file.name) ? theme.successSoft : theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(MediaKind.isAudio(file.name) ? theme.successInk : theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(netdisk.cachedFileURL(for: file) == nil ? "网盘在线 · \(file.kindLabel)" : "已缓存 · \(file.kindLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(playing ? theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { model.playNetdisk(file) }
    }

    private var localQueue: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("播放队列（\(library.playlist.count)）")
                    .font(.system(size: 13.5, weight: .semibold))
                chip("连续播放", system: "play.fill", on: library.settings.continuousPlay) {
                    library.setContinuousPlay(!library.settings.continuousPlay)
                    model.showToast(library.settings.continuousPlay ? "连续播放：开" : "连续播放：关")
                }
                chip("随机", system: "shuffle", on: library.settings.shuffle) {
                    library.setShuffle(!library.settings.shuffle)
                    model.showToast(library.settings.shuffle ? "随机播放：开" : "随机播放：关")
                }
                Spacer()
                Button("加入文件…") { model.openFilesPanel() }
                    .buttonStyle(.bordered)
                Text("拖拽排序 · 自动续播断点")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { theme.separator.frame(height: 1) }

            if library.playlist.isEmpty {
                VStack(spacing: 10) {
                    Text("播放列表是空的")
                        .font(.system(size: 16, weight: .semibold))
                    Text("拖入多个文件，或从百度网盘下载后会自动出现在这里。")
                        .foregroundStyle(theme.text2)
                    Button("打开文件…") { model.openFilesPanel() }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(library.playlist.enumerated()), id: \.element.id) { index, item in
                        row(index: index, item: item)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .listRowSeparator(.hidden)
                            .listRowBackground(theme.background)
                    }
                    .onMove { source, destination in
                        library.movePlaylist(from: source, to: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(index: Int, item: MediaItem) -> some View {
        let playing = item.id == session.currentItem?.id
        return HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text3)
                .frame(width: 20, alignment: .trailing)
            Image(systemName: playing ? "play.fill" : (item.isAudio ? "waveform" : "film"))
                .frame(width: 34, height: 34)
                .background(item.isAudio ? theme.successSoft : theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(item.isAudio ? theme.successInk : theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(meta(item))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                library.removeFromPlaylist(at: index)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("移除")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(playing ? theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { model.play(item) }
    }

    private func meta(_ item: MediaItem) -> String {
        let kind = item.source == .netdisk ? "网盘缓存" : (item.isAudio ? "音频" : "视频")
        let length = item.duration > 0 ? TimeFormat.clock(item.duration) : "时长未知"
        let progress: String
        if item.duration > 0, item.lastPosition > 0 {
            progress = "进度 \(Int((item.lastPosition / item.duration * 100).rounded()))%"
        } else {
            progress = item.playableURL == nil ? "文件缺失" : "未开始"
        }
        let subtitle = item.subtitleRefs.isEmpty ? "字幕待匹配" : "字幕已记录"
        return "\(kind) · \(length) · \(subtitle) · \(progress)"
    }

    private func chip(_ title: String, system: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(on ? theme.accentSoft : theme.sidebar, in: Capsule())
                .overlay(Capsule().stroke(on ? theme.accent.opacity(0.35) : theme.separator))
                .foregroundStyle(on ? theme.accentDeep : theme.text2)
        }
        .buttonStyle(.plain)
    }
}

struct NetdiskScreen: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var netdisk: NetdiskService
    @State private var keyword = ""
    @State private var secretDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            switch netdisk.authPhase {
            case .signedIn:
                browser
            case .waitingForScan:
                waiting
            case .signedOut, .failed:
                signIn
            }
        }
        .background(theme.background)
        .task {
            if case .signedOut = netdisk.authPhase, netdisk.displayName.isEmpty {
                await netdisk.restoreSession()
            }
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接百度网盘")
                .font(.system(size: 20, weight: .semibold))
            Text("常见格式可以直接在线播放。MKV 会边转换边播放，不必先下完整集。授权凭证只进钥匙串，不会上传你的学习记录。")
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            Text(netdisk.rateLimitNotice)
                .font(.system(size: 12))
                .foregroundStyle(theme.orange)
            TextField("App Key", text: Binding(
                get: { netdisk.appKey },
                set: { netdisk.saveCredentials(appKey: $0, secret: secretDraft.isEmpty ? netdisk.secretValue : secretDraft) }
            ))
            .textFieldStyle(.roundedBorder)
            SecureField(netdisk.hasSecret ? "Secret Key（已保存，留空则不修改）" : "Secret Key", text: $secretDraft)
                .textFieldStyle(.roundedBorder)
            Button("获取二维码并授权") {
                if !secretDraft.isEmpty {
                    netdisk.saveCredentials(appKey: netdisk.appKey, secret: secretDraft)
                }
                Task { await netdisk.startAuthorization() }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            if case .failed(let reason) = netdisk.authPhase {
                Text(reason).foregroundStyle(.red).font(.system(size: 12))
            }
            Text("本地文件播放不依赖网盘。拒绝授权或授权失败时，仍然可以打开本机素材。")
                .font(.system(size: 12))
                .foregroundStyle(theme.text3)
        }
        .padding(28)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            Text("用百度网盘 App 扫码授权")
                .font(.system(size: 18, weight: .semibold))
            if let url = netdisk.qrcodeURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 180, height: 180)
            }
            Text("用户码 \(netdisk.userCode)")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
            Button("打开验证页") {
                if let url = URL(string: netdisk.verificationURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            if let message = netdisk.message {
                Text(message).font(.system(size: 12)).foregroundStyle(theme.text2)
            }
            Button("取消") { netdisk.cancelAuthorization() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Array(netdisk.crumbs().enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Text("/").foregroundStyle(theme.text3)
                    }
                    Button(crumb.title) {
                        Task { await netdisk.reload(directory: crumb.path) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: crumb.path == netdisk.directory ? .semibold : .regular))
                }
                Spacer()
                TextField("搜索文件名", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { Task { await netdisk.search(keyword) } }
                Button("刷新") { Task { await netdisk.reload(directory: netdisk.directory) } }
                    .buttonStyle(.bordered)
                Text(quotaText)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
                Button("退出") { netdisk.signOut() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { theme.separator.frame(height: 1) }

            HStack {
                Text("文件名")
                Spacer()
                Text("大小").frame(width: 90, alignment: .leading)
                Text("缓存状态").frame(width: 110, alignment: .leading)
                Text("操作").frame(width: 88, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.text3)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if netdisk.files.isEmpty {
                Text("这个目录是空的，或搜索没有结果。")
                    .foregroundStyle(theme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(netdisk.files) { file in
                            fileRow(file)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            Text(netdisk.rateLimitNotice)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.sidebar)
        }
    }

    private func fileRow(_ file: NetdiskFile) -> some View {
        let snapshot = netdisk.downloads[file.path]
        return HStack(spacing: 10) {
            Image(systemName: file.isDirectory ? "folder" : (file.isPlayable ? "film" : "doc"))
                .frame(width: 34, height: 34)
                .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.system(size: 13)).lineLimit(1)
                Text(file.kindLabel).font(.system(size: 11)).foregroundStyle(theme.text3)
            }
            Spacer()
            Text(file.isDirectory ? "—" : ByteFormat.string(file.size))
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
                .frame(width: 90, alignment: .leading)
            statusBadge(file, snapshot)
                .frame(width: 110, alignment: .leading)
            actionButton(file, snapshot)
                .frame(width: 148, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(theme.background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if file.isDirectory {
                Task { await netdisk.reload(directory: file.path) }
            } else if file.isPlayable {
                model.playNetdisk(file)
            }
        }
    }

    private func statusBadge(_ file: NetdiskFile, _ snapshot: DownloadSnapshot?) -> some View {
        let title: String
        let color: Color
        if file.isDirectory {
            title = "文件夹"
            color = theme.text3
        } else if snapshot?.status == .downloading {
            title = "下载中 \(Int((snapshot?.fraction ?? 0) * 100))%"
            color = theme.orange
        } else if snapshot?.status == .paused {
            title = "已暂停"
            color = theme.orange
        } else if snapshot?.status == .failed {
            title = "失败"
            color = .red
        } else if netdisk.cachedFileURL(for: file) != nil || snapshot?.status == .completed {
            title = "已缓存"
            color = theme.green
        } else {
            title = "未缓存"
            color = theme.text3
        }
        return Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private func actionButton(_ file: NetdiskFile, _ snapshot: DownloadSnapshot?) -> some View {
        HStack(spacing: 6) {
            if file.isDirectory {
                Button("打开") { Task { await netdisk.reload(directory: file.path) } }
                    .buttonStyle(.bordered)
            } else {
                if file.isPlayable {
                    Button("播放") { model.playNetdisk(file) }
                        .buttonStyle(.bordered)
                }
                if snapshot?.status == .downloading {
                    Button("暂停") { netdisk.pause(path: file.path) }
                        .buttonStyle(.bordered)
                } else if netdisk.cachedFileURL(for: file) == nil {
                    Button(snapshot?.status == .paused ? "继续" : "下载") { netdisk.download(file) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.small)
    }

    private var quotaText: String {
        guard netdisk.quotaTotal > 0 else { return netdisk.displayName }
        return "\(netdisk.displayName) · \(ByteFormat.string(netdisk.quotaUsed)) / \(ByteFormat.string(netdisk.quotaTotal))"
    }
}

public struct PlaylistWindow: View {
    @Environment(\.colorScheme) private var systemScheme
    @EnvironmentObject private var model: AppModel

    public init() {}

    private var palette: ThemePalette {
        ThemePalette.resolve(model.library.settings.appearance, system: systemScheme)
    }

    public var body: some View {
        PlaylistScreen()
            .environmentObject(model.session)
            .environmentObject(model.library)
            .environmentObject(model.netdisk)
            .background(palette.background)
            .foregroundStyle(palette.text)
            .tint(palette.accent)
            .environment(\.theme, palette)
            .preferredColorScheme(model.library.settings.appearance.preferred)
            .frame(minWidth: 560, minHeight: 480)
    }
}

public struct NetdiskWindow: View {
    @Environment(\.colorScheme) private var systemScheme
    @EnvironmentObject private var model: AppModel

    public init() {}

    private var palette: ThemePalette {
        ThemePalette.resolve(model.library.settings.appearance, system: systemScheme)
    }

    public var body: some View {
        NetdiskScreen()
            .environmentObject(model.session)
            .environmentObject(model.library)
            .environmentObject(model.netdisk)
            .background(palette.background)
            .foregroundStyle(palette.text)
            .tint(palette.accent)
            .environment(\.theme, palette)
            .preferredColorScheme(model.library.settings.appearance.preferred)
            .frame(minWidth: 720, minHeight: 560)
    }
}
