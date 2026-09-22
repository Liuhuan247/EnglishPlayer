import Foundation

final class WaveformService {
    let directory: URL
    private let extractor: WaveformExtracting
    private var memory: [String: [Float]] = [:]
    private let lock = NSLock()

    init(directory: URL, extractor: WaveformExtracting = WaveformExtractor()) {
        self.directory = directory
        self.extractor = extractor
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cachedPeaks(mediaID: String, index: Int, variant: String = "0") -> [Float]? {
        let key = cacheKey(mediaID, index, variant)
        lock.lock()
        if let peaks = memory[key] {
            lock.unlock()
            return peaks
        }
        lock.unlock()
        let url = fileURL(mediaID, index, variant)
        guard let data = try? Data(contentsOf: url),
              let peaks = try? JSONDecoder().decode([Float].self, from: data) else {
            return nil
        }
        lock.lock()
        memory[key] = peaks
        lock.unlock()
        return peaks
    }

    func peaks(
        mediaID: String,
        index: Int,
        variant: String = "0",
        url: URL,
        start: Double,
        end: Double,
        buckets: Int = 96
    ) async throws -> [Float] {
        if let cached = cachedPeaks(mediaID: mediaID, index: index, variant: variant) {
            return cached
        }
        let extracted = try await extractor.extractPeaks(from: url, start: start, end: end, buckets: buckets)
        store(extracted, mediaID: mediaID, index: index, variant: variant)
        return extracted
    }

    private func store(_ peaks: [Float], mediaID: String, index: Int, variant: String) {
        let key = cacheKey(mediaID, index, variant)
        lock.lock()
        memory[key] = peaks
        lock.unlock()
        let folder = directory.appendingPathComponent(mediaID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(peaks) {
            try? data.write(to: fileURL(mediaID, index, variant), options: .atomic)
        }
    }

    private func cacheKey(_ mediaID: String, _ index: Int, _ variant: String) -> String {
        "\(mediaID)#\(index)#\(variant)"
    }

    private func fileURL(_ mediaID: String, _ index: Int, _ variant: String) -> URL {
        directory
            .appendingPathComponent(mediaID, isDirectory: true)
            .appendingPathComponent("\(index)-\(variant).json")
    }
}
