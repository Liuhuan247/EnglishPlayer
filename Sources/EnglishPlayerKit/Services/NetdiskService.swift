import Combine
import Foundation

enum NetdiskAuthPhase: Equatable {
    case signedOut
    case waitingForScan
    case signedIn
    case failed(String)
}

@MainActor
final class NetdiskService: ObservableObject {
    @Published var files: [NetdiskFile] = []
    @Published var directory = "/"
    @Published var authPhase: NetdiskAuthPhase = .signedOut
    @Published var userCode = ""
    @Published var verificationURL = ""
    @Published var qrcodeURL: URL?
    @Published var displayName = ""
    @Published var quotaUsed: Int64 = 0
    @Published var quotaTotal: Int64 = 0
    @Published var downloads: [String: DownloadSnapshot] = [:]
    @Published var playbackQueue: [NetdiskFile] = []
    @Published var playbackDirectory = ""
    @Published var message: String?
    @Published private(set) var appKey = ""
    var hasSecret: Bool { !secret.isEmpty }
    var secretValue: String { secret }

    let rateLimitNotice = "非会员在线播放和下载都可能被限速。MP4、MOV 等常见格式可以直接播放；MKV 等封装需要先下载。"

    var onFileReady: ((String, String, String) -> Void)?

    private let api: NetdiskAPI
    private let credentials: CredentialStoring
    private let transport: DownloadTransport
    private let cache: CacheManager
    private let store: SQLiteStore
    private var pollTask: Task<Void, Never>?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var secret = ""

    init(
        store: SQLiteStore,
        cache: CacheManager,
        credentials: CredentialStoring,
        http: HTTPClient = URLSessionHTTPClient(),
        transport: DownloadTransport = URLSessionDownloadTransport()
    ) {
        self.store = store
        self.cache = cache
        self.credentials = credentials
        self.api = NetdiskAPI(http: http)
        self.transport = transport
        appKey = (try? credentials.string(account: BaiduAccount.appKey)) ?? ""
        secret = (try? credentials.string(account: BaiduAccount.secret)) ?? ""
    }

    func saveCredentials(appKey: String, secret: String) {
        let trimmedKey = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appKey = trimmedKey
        self.secret = trimmedSecret
        try? credentials.set(trimmedKey, account: BaiduAccount.appKey)
        try? credentials.set(trimmedSecret, account: BaiduAccount.secret)
    }

    func restoreSession() async {
        guard let token = try? credentials.string(account: BaiduAccount.access), !token.isEmpty else {
            authPhase = .signedOut
            return
        }
        authPhase = .signedIn
        await reload(directory: "/")
    }

    func startAuthorization() async {
        let key = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !savedSecret.isEmpty else {
            authPhase = .failed(PlayerError.missingCredentials.localizedDescription)
            return
        }
        do {
            let code = try await api.requestDeviceCode(appKey: key)
            userCode = code.userCode
            verificationURL = code.verificationURL
            qrcodeURL = URL(string: code.qrcodeURL)
            authPhase = .waitingForScan
            message = "用手机扫描二维码，或打开验证页输入用户码 \(code.userCode)。"
            pollTask?.cancel()
            pollTask = Task { await self.poll(code, appKey: key, secret: savedSecret) }
        } catch {
            authPhase = .failed((error as? LocalizedError)?.errorDescription ?? "无法开始授权")
        }
    }

    func cancelAuthorization() {
        pollTask?.cancel()
        if case .waitingForScan = authPhase {
            authPhase = .signedOut
        }
    }

    func signOut() {
        pollTask?.cancel()
        try? credentials.remove(account: BaiduAccount.access)
        try? credentials.remove(account: BaiduAccount.refresh)
        try? credentials.remove(account: BaiduAccount.expiry)
        authPhase = .signedOut
        files = []
        playbackQueue = []
        playbackDirectory = ""
        displayName = ""
        message = "已退出网盘。本地播放不受影响。"
    }

    func reload(directory path: String) async {
        directory = path
        await perform {
            let token = try await self.validToken()
            let listed = try await self.api.list(directory: path, token: token)
            self.files = listed.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            await self.refreshAccount(token: token)
        }
    }

    func search(_ keyword: String) async {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            await reload(directory: directory)
            return
        }
        await perform {
            let token = try await self.validToken()
            self.files = try await self.api.search(keyword: text, token: token)
        }
    }

    func preparePlayback(_ file: NetdiskFile) async -> NetdiskPlayPlan {
        guard file.isPlayable else {
            return .blocked("「\(file.name)」不是可播放的音视频。")
        }
        let folder = NetdiskCatalog.parentDirectory(of: file.path)
        let listed: [NetdiskFile]
        do {
            let token = try await validToken()
            listed = try await api.list(directory: folder, token: token)
        } catch {
            return .blocked((error as? LocalizedError)?.errorDescription ?? "无法读取网盘目录")
        }
        playbackDirectory = folder
        playbackQueue = NetdiskCatalog.playableSorted(listed)

        let subtitlePaths = await subtitlePaths(for: file.name, in: listed)
        if let cached = cachedFileURL(for: file) {
            return .local(remotePath: file.path, title: file.name, cachePath: cached.path, subtitlePaths: subtitlePaths)
        }
        let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
        guard MediaKind.systemNative.contains(ext) else {
            let shown = ext.isEmpty ? "这个封装" : ext.uppercased()
            return .blocked("「\(file.name)」是 \(shown)，当前播放器不能在线播放。可以先下载，下载完成后从缓存播放。")
        }
        do {
            let meta = try await authorizedMeta(fsID: file.fsID)
            guard let remote = URL(string: meta.dlink) else {
                return .blocked("没有拿到「\(file.name)」的播放地址。")
            }
            let token = try await validToken()
            let request = DownloadRequest.make(url: remote, resumeFrom: 0, accessToken: token)
            guard let streamURL = request.url else {
                return .blocked("没有拿到「\(file.name)」的播放地址。")
            }
            return .stream(
                remotePath: file.path,
                title: file.name,
                url: streamURL,
                headers: ["User-Agent": "pan.baidu.com"],
                subtitlePaths: subtitlePaths
            )
        } catch {
            return .blocked((error as? LocalizedError)?.errorDescription ?? "无法连接网盘文件")
        }
    }

    private func subtitlePaths(for mediaName: String, in files: [NetdiskFile]) async -> [String] {
        var paths: [String] = []
        for file in NetdiskCatalog.subtitles(for: mediaName, in: files) {
            if let local = await downloadSmallFile(file) {
                paths.append(local.path)
            }
        }
        return paths
    }

    private func downloadSmallFile(_ file: NetdiskFile) async -> URL? {
        let destination = cache.fileURL(id: MediaItem.stableID(for: file.path), filename: file.name)
        if FileManager.default.fileExists(atPath: destination.path), cache.fileSize(destination.path) > 0 {
            return destination
        }
        do {
            let meta = try await authorizedMeta(fsID: file.fsID)
            guard let remote = URL(string: meta.dlink) else { return nil }
            let token = try await validToken()
            let request = DownloadRequest.make(url: remote, resumeFrom: 0, accessToken: token)
            try await transport.download(request, to: destination, append: false) { _ in }
            guard cache.fileSize(destination.path) > 0 else { return nil }
            return destination
        } catch {
            return nil
        }
    }

    func download(_ file: NetdiskFile) {
        if file.isDirectory {
            Task { await self.reload(directory: file.path) }
            return
        }
        downloadTasks[file.path]?.cancel()
        downloadTasks[file.path] = Task { await self.performDownload(file) }
    }

    func pause(path: String) {
        downloadTasks[path]?.cancel()
        downloadTasks[path] = nil
        if var snapshot = downloads[path] {
            snapshot.status = .paused
            downloads[path] = snapshot
        }
        if let entry = try? store.cache(mediaID: MediaItem.stableID(for: path)) {
            var paused = entry
            paused.status = .paused
            paused.updatedAt = Date()
            try? store.upsertCache(paused)
        }
    }

    func cachedFileURL(for file: NetdiskFile) -> URL? {
        guard let entry = try? store.cache(mediaID: MediaItem.stableID(for: file.path)),
              entry.status == .completed,
              FileManager.default.fileExists(atPath: entry.localPath) else {
            return nil
        }
        return URL(fileURLWithPath: entry.localPath)
    }

    func crumbs() -> [(title: String, path: String)] {
        NetdiskAPI.breadcrumbs(for: directory)
    }

    private func poll(_ code: DeviceCode, appKey: String, secret: String) async {
        var interval = max(1, code.interval)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            if Task.isCancelled { return }
            do {
                let result = try await api.pollToken(deviceCode: code.deviceCode, appKey: appKey, secret: secret)
                switch result {
                case .pending:
                    continue
                case .slowDown:
                    interval += 5
                case .approved(let access, let refresh, let expiresIn):
                    try storeToken(access: access, refresh: refresh, expiresIn: expiresIn)
                    authPhase = .signedIn
                    message = "授权成功。"
                    await reload(directory: "/")
                    return
                case .denied, .expired:
                    authPhase = .failed(PlayerError.authorizationDenied.localizedDescription)
                    return
                }
            } catch {
                authPhase = .failed((error as? LocalizedError)?.errorDescription ?? "授权失败")
                return
            }
        }
    }

    private func performDownload(_ file: NetdiskFile) async {
        let mediaID = MediaItem.stableID(for: file.path)
        let destination = cache.fileURL(id: mediaID, filename: file.name)
        if let existing = try? store.cache(mediaID: mediaID),
           existing.status == .completed,
           FileManager.default.fileExists(atPath: existing.localPath) {
            downloads[file.path] = DownloadSnapshot(status: .completed, bytes: existing.size, total: existing.size)
            onFileReady?(file.path, existing.localPath, file.name)
            message = "已在缓存中，可以直接播放。"
            return
        }

        do {
            try cache.purge(keepingUnder: cacheLimit(), protected: [destination.path])
            var meta = try await authorizedMeta(fsID: file.fsID)
            var resume = FileManager.default.fileExists(atPath: destination.path) ? cache.fileSize(destination.path) : 0
            if resume >= file.size, file.size > 0 {
                resume = 0
            }
            publish(file, status: .downloading, bytes: resume, total: file.size)
            var refreshed = false
            while true {
                if Task.isCancelled { throw CancellationError() }
                let token = try await validToken()
                let request = DownloadRequest.make(
                    url: URL(string: meta.dlink) ?? URL(fileURLWithPath: "/"),
                    resumeFrom: resume,
                    accessToken: token
                )
                do {
                    try await transport.download(request, to: destination, append: resume > 0) { bytes in
                        Task { @MainActor in
                            self.publish(file, status: .downloading, bytes: bytes, total: file.size)
                        }
                    }
                    break
                } catch PlayerError.dlinkExpired where !refreshed {
                    refreshed = true
                    meta = try await authorizedMeta(fsID: file.fsID)
                    message = PlayerError.dlinkExpired.localizedDescription
                    continue
                }
            }
            var entry = CacheEntry(
                mediaID: mediaID,
                netdiskPath: file.path,
                fsID: file.fsID,
                localPath: destination.path,
                size: cache.fileSize(destination.path),
                bytesDownloaded: cache.fileSize(destination.path),
                status: .completed,
                dlink: meta.dlink,
                dlinkExpiry: Date().addingTimeInterval(8 * 60 * 60),
                updatedAt: Date()
            )
            if entry.size == 0 { entry.size = file.size }
            try store.upsertCache(entry)
            publish(file, status: .completed, bytes: entry.bytesDownloaded, total: max(file.size, entry.size))
            if file.isPlayable {
                onFileReady?(file.path, destination.path, file.name)
                message = "下载完成，已加入播放列表。"
            } else {
                message = "下载完成。这个格式不能直接播放，文件已留在缓存里。"
            }
        } catch is CancellationError {
            publish(file, status: .paused, bytes: downloads[file.path]?.bytes ?? 0, total: file.size)
        } catch let error as URLError where error.code == .cancelled {
            publish(file, status: .paused, bytes: downloads[file.path]?.bytes ?? 0, total: file.size)
        } catch {
            publish(file, status: .failed, bytes: downloads[file.path]?.bytes ?? 0, total: file.size)
            message = (error as? LocalizedError)?.errorDescription ?? "下载失败"
        }
    }

    private func authorizedMeta(fsID: Int64) async throws -> RemoteMeta {
        do {
            let token = try await validToken()
            return try await api.fileMeta(fsID: fsID, token: token)
        } catch PlayerError.notAuthorized {
            try await refreshTokens()
            let token = try await validToken()
            return try await api.fileMeta(fsID: fsID, token: token)
        }
    }

    private func perform(_ body: () async throws -> Void) async {
        do {
            try await body()
            if case .failed = authPhase { return }
            authPhase = .signedIn
        } catch PlayerError.notAuthorized {
            do {
                try await refreshTokens()
                try await body()
                authPhase = .signedIn
            } catch {
                authPhase = .failed(PlayerError.authorizationDenied.localizedDescription)
                message = PlayerError.authorizationDenied.localizedDescription
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "网盘请求失败"
        }
    }

    private func refreshAccount(token: String) async {
        if let quota = try? await api.quota(token: token) {
            quotaUsed = quota.used
            quotaTotal = quota.total
        }
        if let name = try? await api.displayName(token: token), !name.isEmpty {
            displayName = name
        }
    }

    private func validToken() async throws -> String {
        if let raw = try credentials.string(account: BaiduAccount.expiry),
           let stamp = TimeInterval(raw),
           Date(timeIntervalSince1970: stamp) < Date().addingTimeInterval(120) {
            try await refreshTokens()
        }
        guard let token = try credentials.string(account: BaiduAccount.access), !token.isEmpty else {
            throw PlayerError.notAuthorized
        }
        return token
    }

    private func refreshTokens() async throws {
        guard let refresh = try credentials.string(account: BaiduAccount.refresh), !refresh.isEmpty else {
            throw PlayerError.notAuthorized
        }
        let key = appKey
        let savedSecret = secret
        guard !key.isEmpty, !savedSecret.isEmpty else { throw PlayerError.missingCredentials }
        let result = try await api.refreshToken(refresh, appKey: key, secret: savedSecret)
        guard case .approved(let access, let newRefresh, let expiresIn) = result else {
            throw PlayerError.authorizationDenied
        }
        try storeToken(access: access, refresh: newRefresh, expiresIn: expiresIn)
    }

    private func storeToken(access: String, refresh: String, expiresIn: Int) throws {
        try credentials.set(access, account: BaiduAccount.access)
        try credentials.set(refresh, account: BaiduAccount.refresh)
        let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        try credentials.set(String(expiry.timeIntervalSince1970), account: BaiduAccount.expiry)
    }

    private func publish(_ file: NetdiskFile, status: CacheStatus, bytes: Int64, total: Int64) {
        downloads[file.path] = DownloadSnapshot(status: status, bytes: bytes, total: total)
        let mediaID = MediaItem.stableID(for: file.path)
        let destination = cache.fileURL(id: mediaID, filename: file.name)
        let entry = CacheEntry(
            mediaID: mediaID,
            netdiskPath: file.path,
            fsID: file.fsID,
            localPath: destination.path,
            size: total,
            bytesDownloaded: bytes,
            status: status,
            dlink: nil,
            dlinkExpiry: nil,
            updatedAt: Date()
        )
        try? store.upsertCache(entry)
    }

    func clearCache(protected: Set<String>) throws -> Int64 {
        let entries = try store.cacheEntries()
        var freed: Int64 = 0
        for entry in entries where !protected.contains(entry.localPath) {
            freed += cache.fileSize(entry.localPath)
            try cache.removeFile(at: entry.localPath)
            try store.deleteCache(mediaID: entry.mediaID)
            downloads[entry.netdiskPath] = nil
        }
        return freed
    }

    private func cacheLimit() -> Int64 {
        Int64((try? store.setting("cache_limit")).flatMap(Int64.init) ?? (10 * 1024 * 1024 * 1024))
    }
}
