import AVFoundation
import Accelerate
import CoreMedia
import Foundation

struct WaveformExtractor: WaveformExtracting {
    func extractPeaks(from url: URL, start: Double, end: Double, buckets: Int) async throws -> [Float] {
        let bucketCount = max(8, buckets)
        let rangeStart = max(0, start)
        let rangeEnd = max(rangeStart + 0.05, end)
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
