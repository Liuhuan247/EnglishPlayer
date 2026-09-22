import CryptoKit
import Foundation

/// AVFoundation 打不开的封装（常见是 MKV 里的杜比音轨）转成它能播的 MP4。
/// 优先复制视频、只把音轨转成 AAC，避免整段重编码。
enum MediaCompat {
    static func prepare(_ source: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try prepareBlocking(source)
        }.value
    }

    static func locateFFmpeg() -> URL? {
        var candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ]
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.insert(support.appendingPathComponent("EnglishPlayer/bin/ffmpeg").path, at: 0)
        }
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func prepareBlocking(_ source: URL) throws -> URL {
        guard let ffmpeg = locateFFmpeg() else {
            throw PlayerError.featureUnavailable(
                "系统播放器打不开「\(source.lastPathComponent)」。需要 ffmpeg 才能转换这种封装，装好后重新打开即可。"
            )
        }
        let directory = cacheDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(cacheName(for: source))
        if reusable(output, source: source) {
            return output
        }

        let attempts: [[String]] = [
            ["-y", "-i", source.path, "-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "copy", "-c:a", "aac", "-ac", "2", "-b:a", "192k", "-sn", output.path],
            ["-y", "-i", source.path, "-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-b:a", "192k", "-sn", output.path],
            ["-y", "-i", source.path, "-vn", "-c:a", "aac", "-ac", "2", "-b:a", "192k", output.path]
        ]
        for arguments in attempts {
            try? FileManager.default.removeItem(at: output)
            if run(ffmpeg, arguments) == 0, fileHasBytes(output) {
                return output
            }
        }
        try? FileManager.default.removeItem(at: output)
        throw PlayerError.damagedFile(source.lastPathComponent)
    }

    private static func reusable(_ output: URL, source: URL) -> Bool {
        guard fileHasBytes(output) else { return false }
        let sourceDate = (try? FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date) ?? .distantPast
        let outputDate = (try? FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate] as? Date) ?? .distantPast
        return outputDate >= sourceDate
    }

    private static func fileHasBytes(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0
    }

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("EnglishPlayer/compat", isDirectory: true)
    }

    private static func cacheName(for source: URL) -> String {
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let token = "\(source.path)|\(size)|\(modified)"
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".mp4"
    }

    private static func run(_ executable: URL, _ arguments: [String]) -> Int32 {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return 1
        }
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
