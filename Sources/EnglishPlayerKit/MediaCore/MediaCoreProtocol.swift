import AppKit
import Foundation

/// 跨端边界。上层只发 open / play / seek / rate，不接触 AVFoundation。
@MainActor
protocol MediaCoreProtocol: AnyObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var volume: Float { get set }
    var hasVideo: Bool { get }
    /// 实际在播的文件。MKV 转成可播放副本后，波形要读这份，而不是原文件。
    var openedURL: URL? { get }
    /// 打开很慢时（例如把 MKV 转成系统能播的文件）用来更新状态栏。
    var statusHandler: ((String) -> Void)? { get set }

    func open(url: URL) async throws
    /// 网盘直链。失败时不转码，交给上层提示用户先下载。
    func openRemote(url: URL, headers: [String: String]) async throws
    func play()
    func pause()
    func seek(to seconds: Double) async
    func setRate(_ rate: Double)
    func setPitchPreservation(_ enabled: Bool)
    func setTimeObserver(_ handler: @escaping (Double) -> Void)
    func attachPreview(to view: NSView)
    func layoutPreview()
    func close()
}

extension MediaCoreProtocol {
    func openRemote(url: URL, headers: [String: String]) async throws {
        try await open(url: url)
    }
}

protocol WaveformExtracting: Sendable {
    func extractPeaks(from url: URL, start: Double, end: Double, buckets: Int) async throws -> [Float]
}

/// V2 跟读录音。V1 只留接口，避免以后改波形数据结构。
protocol FollowReadRecorder: AnyObject {
    func start() async throws
    func stop() async throws -> [Float]
}

final class UnavailableRecorder: FollowReadRecorder {
    func start() async throws {
        throw PlayerError.featureUnavailable("跟读录音将在 V2 提供")
    }

    func stop() async throws -> [Float] {
        throw PlayerError.featureUnavailable("跟读录音将在 V2 提供")
    }
}
