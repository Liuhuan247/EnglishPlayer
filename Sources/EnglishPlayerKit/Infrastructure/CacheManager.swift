import Foundation

/// 网盘文件落地目录。容量清理按文件修改时间从旧到新删，正在播放的路径会被跳过。
final class CacheManager {
    private(set) var directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func setDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
    }

    func fileURL(id: String, filename: String) -> URL {
        let ext = URL(fileURLWithPath: filename).pathExtension
        let safeExt = ext.isEmpty ? "bin" : ext
        return directory.appendingPathComponent("\(id).\(safeExt)")
    }

    func fileSize(_ path: String) -> Int64 {
        let values = try? FileManager.default.attributesOfItem(atPath: path)
        return (values?[.size] as? Int64) ?? (values?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func totalSize() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return urls.reduce(0) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + Int64(size)
        }
    }

    func removeFile(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    /// 删到上限以内。返回释放的字节数。
    @discardableResult
    func purge(keepingUnder limit: Int64, protected: Set<String> = []) throws -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = urls.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        var used = totalSize()
        var freed: Int64 = 0
        guard used > limit else { return 0 }
        for url in sorted {
            if used <= limit { break }
            if protected.contains(url.path) { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try FileManager.default.removeItem(at: url)
            used -= size
            freed += size
        }
        return freed
    }
}
