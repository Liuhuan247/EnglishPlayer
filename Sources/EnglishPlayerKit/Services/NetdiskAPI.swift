import Foundation

struct NetdiskFile: Identifiable, Equatable {
    var fsID: Int64
    var path: String
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?

    var id: String { path }

    var kindLabel: String {
        if isDirectory { return "文件夹" }
        let ext = URL(fileURLWithPath: name).pathExtension.uppercased()
        if MediaKind.video.contains(ext.lowercased()) { return "视频 · \(ext)" }
        if MediaKind.audio.contains(ext.lowercased()) { return "音频 · \(ext)" }
        return ext.isEmpty ? "文件" : ext
    }

    var isPlayable: Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return MediaKind.video.contains(ext) || MediaKind.audio.contains(ext)
    }
}

struct DownloadSnapshot: Equatable {
    var status: CacheStatus
    var bytes: Int64
    var total: Int64

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(bytes) / Double(total))
    }
}

enum TokenPoll: Equatable {
    case pending
    case slowDown
    case approved(access: String, refresh: String, expiresIn: Int)
    case denied
    case expired
}

struct DeviceCode: Equatable {
    var deviceCode: String
    var userCode: String
    var verificationURL: String
    var qrcodeURL: String
    var interval: Int
}

struct RemoteMeta: Equatable {
    var dlink: String
    var size: Int64
    var filename: String
}

enum BaiduAccount {
    static let appKey = "baidu.appKey"
    static let secret = "baidu.secret"
    static let access = "baidu.accessToken"
    static let refresh = "baidu.refreshToken"
    static let expiry = "baidu.expiresAt"
}

struct NetdiskAPI {
    var http: HTTPClient

    func requestDeviceCode(appKey: String) async throws -> DeviceCode {
        let url = try Self.url("https://openapi.baidu.com/oauth/2.0/device/code", [
            URLQueryItem(name: "response_type", value: "device_code"),
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "scope", value: "basic,netdisk")
        ])
        let json = try await jsonObject(url)
        if let error = json["error"] as? String, !error.isEmpty {
            throw PlayerError.network("获取二维码失败：\(error)")
        }
        guard let device = json["device_code"] as? String, let user = json["user_code"] as? String else {
            throw PlayerError.network("授权接口没有返回设备码")
        }
        return DeviceCode(
            deviceCode: device,
            userCode: user,
            verificationURL: (json["verification_url"] as? String) ?? "https://openapi.baidu.com/device",
            qrcodeURL: (json["qrcode_url"] as? String) ?? "",
            interval: (json["interval"] as? Int) ?? 5
        )
    }

    func pollToken(deviceCode: String, appKey: String, secret: String) async throws -> TokenPoll {
        let url = try Self.url("https://openapi.baidu.com/oauth/2.0/token", [
            URLQueryItem(name: "grant_type", value: "device_token"),
            URLQueryItem(name: "code", value: deviceCode),
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "client_secret", value: secret)
        ])
        return try await decodeToken(url)
    }

    func refreshToken(_ refresh: String, appKey: String, secret: String) async throws -> TokenPoll {
        let url = try Self.url("https://openapi.baidu.com/oauth/2.0/token", [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "client_secret", value: secret)
        ])
        return try await decodeToken(url)
    }

    func list(directory: String, token: String) async throws -> [NetdiskFile] {
        var start = 0
        var collected: [NetdiskFile] = []
        while start < 2_000 {
            let page = try await listPage(directory: directory, token: token, start: start)
            collected.append(contentsOf: page)
            if page.count < 200 { break }
            start += 200
        }
        return collected
    }

    private func listPage(directory: String, token: String, start: Int) async throws -> [NetdiskFile] {
        let url = try Self.url("https://pan.baidu.com/rest/2.0/xpan/file", [
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "dir", value: directory),
            URLQueryItem(name: "order", value: "name"),
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "folder", value: "0"),
            URLQueryItem(name: "access_token", value: token)
        ])
        return try await files(from: url)
    }

    func search(keyword: String, token: String) async throws -> [NetdiskFile] {
        let url = try Self.url("https://pan.baidu.com/rest/2.0/xpan/file", [
            URLQueryItem(name: "method", value: "search"),
            URLQueryItem(name: "key", value: keyword),
            URLQueryItem(name: "dir", value: "/"),
            URLQueryItem(name: "recursion", value: "1"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "num", value: "100"),
            URLQueryItem(name: "access_token", value: token)
        ])
        return try await files(from: url)
    }

    func fileMeta(fsID: Int64, token: String) async throws -> RemoteMeta {
        let url = try Self.url("https://pan.baidu.com/rest/2.0/xpan/multimedia", [
            URLQueryItem(name: "method", value: "filemetas"),
            URLQueryItem(name: "fsids", value: "[\(fsID)]"),
            URLQueryItem(name: "dlink", value: "1"),
            URLQueryItem(name: "access_token", value: token)
        ])
        let json = try await jsonObject(url)
        try Self.checkErrno(json)
        let list = json["list"] as? [[String: Any]] ?? []
        guard let first = list.first, let dlink = first["dlink"] as? String, !dlink.isEmpty else {
            throw PlayerError.network("没有拿到下载地址")
        }
        let size = Self.int64(first["size"])
        let name = (first["filename"] as? String) ?? (first["server_filename"] as? String) ?? "media"
        return RemoteMeta(dlink: dlink, size: size, filename: name)
    }

    func quota(token: String) async throws -> (used: Int64, total: Int64) {
        let url = try Self.url("https://pan.baidu.com/api/quota", [
            URLQueryItem(name: "checkfree", value: "1"),
            URLQueryItem(name: "checkexpire", value: "1"),
            URLQueryItem(name: "access_token", value: token)
        ])
        let json = try await jsonObject(url)
        try Self.checkErrno(json)
        return (Self.int64(json["used"]), Self.int64(json["total"]))
    }

    func displayName(token: String) async throws -> String {
        let url = try Self.url("https://pan.baidu.com/rest/2.0/xpan/nas", [
            URLQueryItem(name: "method", value: "uinfo"),
            URLQueryItem(name: "access_token", value: token)
        ])
        let json = try await jsonObject(url)
        try Self.checkErrno(json)
        let netdisk = json["netdisk_name"] as? String ?? ""
        let baidu = json["baidu_name"] as? String ?? ""
        return netdisk.isEmpty ? baidu : netdisk
    }

    static func breadcrumbs(for path: String) -> [(title: String, path: String)] {
        if path.isEmpty || path == "/" {
            return [("我的网盘", "/")]
        }
        var crumbs: [(String, String)] = [("我的网盘", "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            crumbs.append((String(part), current))
        }
        return crumbs
    }

    private func decodeToken(_ url: URL) async throws -> TokenPoll {
        let json = try await jsonObject(url, allowHTTPError: true)
        let error = json["error"] as? String
        switch error {
        case nil, "":
            guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
                return .pending
            }
            let expires = (json["expires_in"] as? Int) ?? Int(Self.int64(json["expires_in"]))
            return .approved(access: access, refresh: refresh, expiresIn: expires == 0 ? 2_592_000 : expires)
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown
        case "expired_token", "invalid_grant":
            return .expired
        case "access_denied":
            return .denied
        default:
            return .denied
        }
    }

    private func files(from url: URL) async throws -> [NetdiskFile] {
        let json = try await jsonObject(url)
        try Self.checkErrno(json)
        let list = json["list"] as? [[String: Any]] ?? []
        return list.compactMap(Self.file(from:))
    }

    private func jsonObject(_ url: URL, allowHTTPError: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        let response = try await http.send(request)
        if !allowHTTPError, !(200...299).contains(response.status) {
            throw PlayerError.network("HTTP \(response.status)")
        }
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw PlayerError.network("网盘返回了无法识别的数据")
        }
        return object
    }

    private static func checkErrno(_ json: [String: Any]) throws {
        let errno = Int(int64(json["errno"]))
        if errno == 0 { return }
        if errno == -6 { throw PlayerError.notAuthorized }
        throw PlayerError.network("网盘接口错误 \(errno)")
    }

    private static func file(from json: [String: Any]) -> NetdiskFile? {
        let path = (json["path"] as? String) ?? ""
        guard !path.isEmpty else { return nil }
        let name = (json["server_filename"] as? String) ?? URL(fileURLWithPath: path).lastPathComponent
        let mtime = int64(json["server_mtime"])
        return NetdiskFile(
            fsID: int64(json["fs_id"]),
            path: path,
            name: name,
            isDirectory: int64(json["isdir"]) != 0,
            size: int64(json["size"]),
            modified: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil
        )
    }

    private static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as Int64: return number
        case let number as Int: return Int64(number)
        case let number as NSNumber: return number.int64Value
        case let text as String: return Int64(text) ?? 0
        default: return 0
        }
    }

    private static func url(_ raw: String, _ items: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: raw) else {
            throw PlayerError.network("地址无效")
        }
        components.queryItems = items
        guard let url = components.url else {
            throw PlayerError.network("地址无效")
        }
        return url
    }
}
