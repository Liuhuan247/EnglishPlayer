import Foundation

struct HTTPResponseBox {
    var status: Int
    var headers: [String: String]
    var body: Data
}

protocol HTTPClient: AnyObject {
    func send(_ request: URLRequest) async throws -> HTTPResponseBox
}

final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> HTTPResponseBox {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PlayerError.network("无效的网络响应")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers["\(key)".lowercased()] = "\(value)"
            }
            return HTTPResponseBox(status: http.statusCode, headers: headers, body: data)
        } catch let error as PlayerError {
            throw error
        } catch {
            throw PlayerError.network(error.localizedDescription)
        }
    }
}

protocol DownloadTransport: AnyObject {
    func download(
        _ request: URLRequest,
        to destination: URL,
        append: Bool,
        onProgress: @escaping (Int64) -> Void
    ) async throws
}

/// 流式写入，避免把网盘大文件整段读进内存。中断后靠已写入的字节做 Range 续传。
final class URLSessionDownloadTransport: DownloadTransport {
    func download(
        _ request: URLRequest,
        to destination: URL,
        append: Bool,
        onProgress: @escaping (Int64) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlayerError.network("无效的下载响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PlayerError.dlinkExpired
        }
        if http.statusCode == 429 || http.statusCode == 509 {
            throw PlayerError.rateLimited
        }
        guard (200...299).contains(http.statusCode) else {
            throw PlayerError.network("下载失败（HTTP \(http.statusCode)）")
        }

        if !append {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        } else if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        if append {
            try handle.seekToEnd()
        }
        var written: Int64 = 0
        if append {
            written = Int64(try handle.offset())
        }

        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                onProgress(written)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            onProgress(written)
        }
    }
}

enum DownloadRequest {
    static func make(url: URL, resumeFrom: Int64, accessToken: String?) -> URLRequest {
        var target = url
        if let accessToken, !url.absoluteString.contains("access_token=") {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = components?.queryItems ?? []
            items.append(URLQueryItem(name: "access_token", value: accessToken))
            components?.queryItems = items
            if let updated = components?.url {
                target = updated
            }
        }
        var request = URLRequest(url: target)
        request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    static func shouldRefreshDlink(statusCode: Int?, expiry: Date?, now: Date = Date()) -> Bool {
        if statusCode == 401 || statusCode == 403 { return true }
        if let expiry, expiry.timeIntervalSince(now) < 60 { return true }
        return false
    }
}
