import AVFoundation
import Accelerate
import CoreMedia
import Foundation

struct WaveformExtractor: WaveformExtracting {
    func extractPeaks(from url: URL, start: Double, end: Double, buckets: Int, headers: [String: String]) async throws -> [Float] {
        let bucketCount = max(8, buckets)
        let rangeStart = max(0, start)
        let rangeEnd = max(rangeStart + 0.05, end)
        if !url.isFileURL {
            let pcm = try await remotePCM(url: url, headers: headers, start: rangeStart, end: rangeEnd)
            return Self.peaks(from: Self.samples(fromPCM16: pcm), buckets: bucketCount)
        }
        do {
            return try await decode(url, start: rangeStart, end: rangeEnd, buckets: bucketCount)
        } catch {
            let ext = url.pathExtension.lowercased()
            guard !MediaKind.systemNative.contains(ext) else { throw error }
            let prepared = try await MediaCompat.prepare(url)
            guard prepared.standardizedFileURL != url.standardizedFileURL else { throw error }
            return try await decode(prepared, start: rangeStart, end: rangeEnd, buckets: bucketCount)
        }
    }

    /// 只拉当前句的声音。-ss 放在输入前，网盘按区间取数据，不用把整集下完。
    private func remotePCM(url: URL, headers: [String: String], start: Double, end: Double) async throws -> Data {
        guard let ffmpeg = MediaCompat.locateFFmpeg() else {
            throw PlayerError.featureUnavailable("需要 ffmpeg 才能读取在线视频的波形。")
        }
        let duration = max(0.05, end - start)
        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error"]
        let agent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        arguments += ["-user_agent", (agent?.isEmpty == false ? agent! : "pan.baidu.com")]
        let extra = headers.filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
        if !extra.isEmpty {
            let block = extra.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            arguments += ["-headers", block]
        }
        arguments += [
            "-ss", String(format: "%.3f", start),
            "-i", url.absoluteString,
            "-t", String(format: "%.3f", duration),
            "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"
        ]
        let job = PCMJob()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try job.run(ffmpeg, arguments)
            }.value
        } onCancel: {
            job.stop()
        }
    }

    static func samples(fromPCM16 data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        var samples = [Float]()
        samples.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                samples.append(Float(Int16(littleEndian: pointer[index])) / 32768)
            }
        }
        return samples
    }

    private func decode(_ url: URL, start: Double, end: Double, buckets: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw PlayerError.waveformFailed(error.localizedDescription)
        }
        guard let track = tracks.first else {
            throw PlayerError.noAudioTrack
        }
        return try readPeaks(asset: asset, track: track, start: start, end: end, buckets: buckets)
    }

    private func readPeaks(asset: AVAsset, track: AVAssetTrack, start: Double, end: Double, buckets: Int) throws -> [Float] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw PlayerError.waveformFailed(error.localizedDescription)
        }
        let startTime = CMTime(seconds: start, preferredTimescale: 600)
        let duration = CMTime(seconds: end - start, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: startTime, duration: duration)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw PlayerError.waveformFailed(reader.error?.localizedDescription ?? "无法读取音频")
        }

        var samples: [Float] = []
        samples.reserveCapacity(48_000)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            let count = data.count / MemoryLayout<Int16>.size
            data.withUnsafeBytes { raw in
                let pointer = raw.bindMemory(to: Int16.self)
                for index in 0..<count {
                    samples.append(Float(pointer[index]) / 32768)
                }
            }
        }
        if reader.status == .failed {
            throw PlayerError.waveformFailed(reader.error?.localizedDescription ?? "读取中断")
        }
        return Self.peaks(from: samples, buckets: buckets)
    }

    static func peaks(from samples: [Float], buckets: Int) -> [Float] {
        guard buckets > 0 else { return [] }
        if samples.isEmpty {
            return Array(repeating: 0, count: buckets)
        }
        var envelope = [Float](repeating: 0, count: buckets)
        let chunk = max(1, samples.count / buckets)
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            for index in 0..<buckets {
                let offset = min(index * chunk, samples.count)
                let available = samples.count - offset
                if available <= 0 { break }
                let length = index == buckets - 1 ? available : min(chunk, available)
                var peak: Float = 0
                vDSP_maxmgv(base.advanced(by: offset), 1, &peak, vDSP_Length(length))
                envelope[index] = peak
            }
        }
        let maximum = envelope.max() ?? 0
        guard maximum > 0.0001 else { return envelope }
        return envelope.map { $0 / maximum }
    }
}

private final class PCMJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        let running = process
        lock.unlock()
        running?.terminate()
    }

    func run(_ ffmpeg: URL, _ arguments: [String]) throws -> Data {
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        lock.lock()
        self.process = process
        lock.unlock()
        defer {
            lock.lock()
            self.process = nil
            lock.unlock()
        }
        try process.run()
        let collected = LockedPCM()
        let failed = LockedText()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collected.set(output.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let data = error.fileHandleForReading.readDataToEndOfFile()
            failed.set(String(data: data, encoding: .utf8) ?? "")
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        lock.lock()
        let cancelled = stopped
        lock.unlock()
        if cancelled { throw CancellationError() }
        let pcm = collected.value
        if process.terminationStatus != 0 || pcm.isEmpty {
            let reason = failed.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let brief = reason.split(separator: "\n").last.map(String.init) ?? "没有读到这一句的声音"
            throw PlayerError.waveformFailed(String(brief.prefix(120)))
        }
        return pcm
    }
}

private final class LockedPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }
    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func set(_ text: String) {
        lock.lock()
        self.text = text
        lock.unlock()
    }
    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}
