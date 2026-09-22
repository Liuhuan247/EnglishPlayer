import Foundation
import Network

/// 本机回环上的只读文件服务。AVPlayer 打不开 file:// 的 m3u8，只认 http。
final class LoopbackFileServer: @unchecked Sendable {
    private let root: URL
    private var listener: NWListener?
    private let once = OnceGate()

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/")!
                    self.once.fire {
                        continuation.resume(returning: url)
                    }
                case .failed(let error):
                    self.once.fire {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        readHeader(connection, buffer: Data())
    }

    private func readHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let marker = next.range(of: Data("\r\n\r\n".utf8)) {
                let header = Data(next[..<marker.lowerBound])
                self.respond(connection, header: header)
                return
            }
            if isComplete || error != nil || next.count > 64 * 1024 {
                connection.cancel()
                return
            }
            self.readHeader(connection, buffer: next)
        }
    }

    private func respond(_ connection: NWConnection, header: Data) {
        let text = String(data: header, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2, request[0] == "GET" else {
            send(connection, status: 405, body: Data())
            return
        }
        guard let file = file(for: String(request[1])) else {
            send(connection, status: 404, body: Data())
            return
        }
        guard let body = try? Data(contentsOf: file) else {
            send(connection, status: 404, body: Data())
            return
        }
        let range = lines.first { $0.lowercased().hasPrefix("range:") }
        if let range, let slice = byteRange(range, length: body.count) {
            send(connection, status: 206, body: Data(body[slice]), type: contentType(file), total: body.count, range: slice)
            return
        }
        send(connection, status: 200, body: body, type: contentType(file))
    }

    private func file(for rawPath: String) -> URL? {
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        let decoded = path.removingPercentEncoding ?? path
        let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        guard !relative.isEmpty, !relative.contains(".."), !relative.hasPrefix("/") else { return nil }
        let file = root.appendingPathComponent(relative).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return file
    }

    private func byteRange(_ header: String, length: Int) -> Range<Int>? {
        let value = header.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard value.hasPrefix("bytes=") else { return nil }
        let span = value.dropFirst("bytes=".count)
        let parts = span.split(separator: "-", maxSplits: 1).map(String.init)
        guard let startText = parts.first, let start = Int(startText), start >= 0, start < length else { return nil }
        let end: Int
        if parts.count > 1, let parsed = Int(parts[1]), parsed >= start {
            end = min(parsed, length - 1)
        } else {
            end = length - 1
        }
        return start..<(end + 1)
    }

    private func contentType(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "m3u8":
            return "application/vnd.apple.mpegurl"
        case "m4s", "mp4", "m4v":
            return "video/mp4"
        case "ts":
            return "video/mp2t"
        default:
            return "application/octet-stream"
        }
    }

    private func send(_ connection: NWConnection, status: Int, body: Data, type: String = "text/plain", total: Int? = nil, range: Range<Int>? = nil) {
        let reason = status == 200 ? "OK" : status == 206 ? "Partial Content" : status == 404 ? "Not Found" : "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n"
        if let range, let total {
            head += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire(_ body: () -> Void) {
        lock.lock()
        let should = !fired
        fired = true
        lock.unlock()
        if should { body() }
    }
}
