import AppKit
import Foundation

struct MPVLoaded {
    var duration: Double
    var hasVideo: Bool
}

/// mpv 直接播 MKV、HEVC 和网盘直链。系统播放器接不住的封装不再转码。
@MainActor
final class MPVPlayerKit: MediaCoreProtocol {
    private let library: MPVLibrary
    private let handle: OpaquePointer
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "englishplayer.mpv")
    private let bridge = MPVBridge()
    private var render: OpaquePointer?
    private var glView: MPVGLView?
    private weak var previewHost: NSView?
    private var tick: ((Double) -> Void)?
    private var openWait: OpenWait?
    private var waitingForDuration = false
    private var playing = false
    private var volumeCache: Float = 1
    private var pitchPreservation = true
    private var desiredRate: Double = 1
    private var bufferingHandler: ((Bool) -> Void)?
    private var cachePaused = false
    private var coreSeeking = false

    private(set) var openedURL: URL?
    private(set) var hasVideo = false
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    var statusHandler: ((String) -> Void)?

    var isPlaying: Bool { playing }

    var volume: Float {
        get { volumeCache }
        set {
            volumeCache = min(1, max(0, newValue))
            let value = volumeCache
            queue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.library.flag(self.handle, "mute", value == 0)
                var level = Double(value * 100)
                _ = "volume".withCString { name in
                    withUnsafeMutablePointer(to: &level) { pointer in
                        self.library.setProperty(self.handle, name, MPVLibrary.formatDouble, UnsafeMutableRawPointer(pointer))
                    }
                }
                self.lock.unlock()
            }
        }
    }

    init?() {
        guard let library = MPVLibrary.load() else { return nil }
        self.library = library
        var created: OpaquePointer?
        var ready = false
        queue.sync {
            created = library.create()
            guard let created else { return }
            let options = [
                "vo": "libmpv",
                "hwdec": "auto-safe",
                "keep-open": "yes",
                "idle": "yes",
                "force-window": "no",
                "osc": "no",
                "ytdl": "no",
                "sub-auto": "no",
                "audio-pitch-correction": "yes",
                "input-default-bindings": "no",
                "input-vo-keyboard": "no",
                "terminal": "no"
            ]
            for (name, value) in options {
                _ = library.option(created, name, value)
            }
            ready = library.initialize(created) >= 0
        }
        guard let created, ready else { return nil }
        handle = created
        bridge.kit = self
        let raw = Unmanaged.passUnretained(bridge).toOpaque()
        queue.sync {
            library.setWakeup(created, bridge.wakeup, raw)
            library.flag(created, "pause", true)
            _ = "time-pos".withCString { library.observeProperty(created, 0, $0, MPVLibrary.formatDouble) }
            _ = "duration".withCString { library.observeProperty(created, 0, $0, MPVLibrary.formatDouble) }
            _ = "pause".withCString { library.observeProperty(created, 0, $0, MPVLibrary.formatFlag) }
            _ = "paused-for-cache".withCString { library.observeProperty(created, 0, $0, MPVLibrary.formatFlag) }
            _ = "seeking".withCString { library.observeProperty(created, 0, $0, MPVLibrary.formatFlag) }
        }
        if let view = MPVGLView(kit: self) {
            glView = view
            view.openGLContext?.makeCurrentContext()
            prepareRenderIfNeeded()
        }
    }

    func open(url: URL) async throws {
        guard MediaKind.isPlayable(url) else {
            throw PlayerError.unsupportedFormat(url.pathExtension.lowercased())
        }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            throw PlayerError.fileMissing
        }
        try await load(url, headers: [:])
    }

    func openRemote(url: URL, headers: [String: String]) async throws {
        statusHandler?("正在打开「\(url.lastPathComponent)」…")
        try await load(url, headers: headers)
    }

    func openRemux(url: URL, headers: [String: String]) async throws {
        try await openRemote(url: url, headers: headers)
    }

    func play() {
        playing = true
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            var speed = self.desiredRate
            _ = "speed".withCString { name in
                withUnsafeMutablePointer(to: &speed) { pointer in
                    self.library.setProperty(self.handle, name, MPVLibrary.formatDouble, UnsafeMutableRawPointer(pointer))
                }
            }
            self.library.flag(self.handle, "pause", false)
            self.lock.unlock()
        }
    }

    func pause() {
        playing = false
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.library.flag(self.handle, "pause", true)
            self.lock.unlock()
        }
    }

    func seek(to seconds: Double) async {
        let target = max(0, seconds)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.lock.lock()
                _ = self.library.command(self.handle, ["seek", String(format: "%.3f", target), "absolute+exact"])
                self.lock.unlock()
                continuation.resume()
            }
        }
    }

    func setRate(_ rate: Double) {
        desiredRate = rate
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            var speed = rate
            _ = "speed".withCString { name in
                withUnsafeMutablePointer(to: &speed) { pointer in
                    self.library.setProperty(self.handle, name, MPVLibrary.formatDouble, UnsafeMutableRawPointer(pointer))
                }
            }
            self.lock.unlock()
        }
    }

    func setPitchPreservation(_ enabled: Bool) {
        pitchPreservation = enabled
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            _ = self.library.property(self.handle, "audio-pitch-correction", enabled ? "yes" : "no")
            self.lock.unlock()
        }
    }

    func setTimeObserver(_ handler: @escaping (Double) -> Void) {
        tick = handler
    }

    func setBufferingObserver(_ handler: @escaping (Bool) -> Void) {
        bufferingHandler = handler
    }

    func attachPreview(to view: NSView) {
        previewHost = view
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        if glView == nil {
            glView = MPVGLView(kit: self)
        }
        guard let glView else { return }
        if glView.superview !== view {
            glView.removeFromSuperview()
            glView.frame = view.bounds
            glView.autoresizingMask = [.width, .height]
            view.addSubview(glView)
        }
    }

    func layoutPreview() {
        glView?.frame = previewHost?.bounds ?? .zero
    }

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            _ = self.library.command(self.handle, ["stop"])
            self.lock.unlock()
        }
        openedURL = nil
        duration = 0
        currentTime = 0
        hasVideo = false
        playing = false
    }

    func render(width: Int32, height: Int32) {
        guard width > 0, height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        prepareRenderIfNeeded()
        guard let render else { return }
        _ = library.renderUpdate(render)
        var fbo = MPVOpenGLFBO(fbo: 0, width: width, height: height, internalFormat: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var params = [
                    MPVRenderParam(type: 3, data: UnsafeMutableRawPointer(fboPointer)),
                    MPVRenderParam(type: 4, data: UnsafeMutableRawPointer(flipPointer)),
                    MPVRenderParam(type: 0, data: nil)
                ]
                _ = params.withUnsafeMutableBufferPointer { buffer in
                    library.renderFrame(render, UnsafeMutableRawPointer(buffer.baseAddress!))
                }
            }
        }
    }

    fileprivate func drain() {
        lock.lock()
        while true {
            let event = library.waitEvent(handle, 0).assumingMemoryBound(to: MPVEvent.self)
            let id = event.pointee.eventID
            if id == MPVLibrary.eventNone { break }
            if id == MPVLibrary.eventFileLoaded {
                let loaded = MPVLoaded(duration: library.doubleProperty(handle, "duration") ?? 0, hasVideo: hasPicture())
                if loaded.duration > 0 {
                    let wait = openWait
                    openWait = nil
                    waitingForDuration = false
                    lock.unlock()
                    wait?.finish(.success(loaded))
                    lock.lock()
                } else {
                    waitingForDuration = openWait != nil
                }
                continue
            }
            if id == MPVLibrary.eventEndFile, let data = event.pointee.data {
                let reason = data.load(as: Int32.self)
                let detail = data.advanced(by: MemoryLayout<Int32>.stride).load(as: Int32.self)
                if reason == MPVLibrary.endFileError, let wait = openWait {
                    openWait = nil
                    waitingForDuration = false
                    let message = library.describe(detail == 0 ? event.pointee.error : detail)
                    lock.unlock()
                    wait.finish(.failure(PlayerError.damagedFile(message)))
                    lock.lock()
                }
            }
            if id == MPVLibrary.eventPropertyChange, let data = event.pointee.data {
                let property = data.assumingMemoryBound(to: MPVEventProperty.self).pointee
                let name = property.name.map { String(cString: $0) } ?? ""
                if name == "time-pos", property.format == MPVLibrary.formatDouble, let data = property.data {
                    let time = data.assumingMemoryBound(to: Double.self).pointee
                    lock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, time.isFinite else { return }
                        self.currentTime = time
                        self.tick?(time)
                    }
                    lock.lock()
                } else if name == "pause", property.format == MPVLibrary.formatFlag, let data = property.data {
                    let paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                    lock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.playing = !paused
                    }
                    lock.lock()
                } else if name == "paused-for-cache" || name == "seeking", property.format == MPVLibrary.formatFlag, let data = property.data {
                    let active = data.assumingMemoryBound(to: Int32.self).pointee != 0
                    if name == "paused-for-cache" {
                        cachePaused = active
                    } else {
                        coreSeeking = active
                    }
                    let busy = cachePaused || coreSeeking
                    lock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.bufferingHandler?(busy)
                    }
                    lock.lock()
                } else if name == "duration", property.format == MPVLibrary.formatDouble, let data = property.data {
                    let value = data.assumingMemoryBound(to: Double.self).pointee
                    if value.isFinite, value > 0 {
                        if waitingForDuration, let wait = openWait {
                            openWait = nil
                            waitingForDuration = false
                            let loaded = MPVLoaded(duration: value, hasVideo: hasPicture())
                            lock.unlock()
                            wait.finish(.success(loaded))
                            lock.lock()
                        } else {
                            lock.unlock()
                            DispatchQueue.main.async { [weak self] in
                                if self?.duration == 0 { self?.duration = value }
                            }
                            lock.lock()
                        }
                    }
                }
            }
        }
        lock.unlock()
        glView?.needsDisplay = true
    }

    private func load(_ url: URL, headers: [String: String]) async throws {
        let loaded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MPVLoaded, Error>) in
            let wait = OpenWait(continuation)
            queue.async { [weak self] in
                guard let self else {
                    wait.finish(.failure(PlayerError.damagedFile(url.lastPathComponent)))
                    return
                }
                self.lock.lock()
                self.openWait?.finish(.failure(CancellationError()))
                self.openWait = wait
                if let agent = headers["User-Agent"] {
                    _ = self.library.property(self.handle, "user-agent", agent)
                }
                let target = url.isFileURL ? url.path : url.absoluteString
                let status = self.library.command(self.handle, ["loadfile", target, "replace"])
                self.lock.unlock()
                if status < 0 {
                    self.lock.lock()
                    self.openWait = nil
                    self.waitingForDuration = false
                    self.lock.unlock()
                    wait.finish(.failure(PlayerError.damagedFile(self.library.describe(status))))
                    return
                }
                self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    guard self.openWait === wait else {
                        self.lock.unlock()
                        return
                    }
                    self.openWait = nil
                    self.waitingForDuration = false
                    let duration = self.library.doubleProperty(self.handle, "duration") ?? 0
                    let loaded = MPVLoaded(duration: duration, hasVideo: self.hasPicture())
                    self.lock.unlock()
                    if duration > 0 {
                        wait.finish(.success(loaded))
                    } else {
                        wait.finish(.failure(PlayerError.network("播放器等待超时")))
                    }
                }
            }
        }
        duration = loaded.duration
        hasVideo = loaded.hasVideo
        openedURL = url
        currentTime = 0
        glView?.needsDisplay = true
    }

    private func hasPicture() -> Bool {
        let format = library.stringProperty(handle, "video-format") ?? ""
        return !format.isEmpty
    }

    private func prepareRenderIfNeeded() {
        guard render == nil, let glView else { return }
        glView.openGLContext?.makeCurrentContext()
        var gl = MPVLibrary.openGLInit()
        var api = strdup("opengl")
        defer { free(api) }
        var created: OpaquePointer?
        let status = withUnsafeMutablePointer(to: &gl) { glPointer in
            var params = [
                MPVRenderParam(type: 1, data: UnsafeMutableRawPointer(api)),
                MPVRenderParam(type: 2, data: UnsafeMutableRawPointer(glPointer)),
                MPVRenderParam(type: 0, data: nil)
            ]
            return params.withUnsafeMutableBufferPointer { buffer in
                library.renderCreate(&created, handle, UnsafeMutableRawPointer(buffer.baseAddress!))
            }
        }
        guard status >= 0, let created else { return }
        render = created
        let raw = Unmanaged.passUnretained(glView).toOpaque()
        library.renderSetUpdate(created, { pointer in
            guard let pointer else { return }
            let view = Unmanaged<MPVGLView>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { view.needsDisplay = true }
        }, raw)
    }

    deinit {
        let library = library
        let handle = handle
        let render = render
        queue.sync {
            if let render {
                library.renderFree(render)
            }
            library.destroy(handle)
        }
    }
}

private final class OpenWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MPVLoaded, Error>?

    init(_ continuation: CheckedContinuation<MPVLoaded, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<MPVLoaded, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class MPVBridge: @unchecked Sendable {
    weak var kit: MPVPlayerKit?
    let wakeup: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
        guard let pointer else { return }
        let bridge = Unmanaged<MPVBridge>.fromOpaque(pointer).takeUnretainedValue()
        Task { @MainActor in
            bridge.kit?.drain()
        }
    }
}

final class MPVGLView: NSOpenGLView {
    weak var kit: MPVPlayerKit?

    init?(kit: MPVPlayerKit) {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile),
            UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            0
        ]
        guard let format = NSOpenGLPixelFormat(attributes: attributes) else { return nil }
        super.init(frame: .zero, pixelFormat: format)
        self.kit = kit
        wantsBestResolutionOpenGLSurface = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("未使用")
    }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        openGLContext?.update()
    }

    override func draw(_ dirtyRect: NSRect) {
        openGLContext?.makeCurrentContext()
        let size = convertToBacking(bounds).size
        kit?.render(width: Int32(size.width.rounded()), height: Int32(size.height.rounded()))
        openGLContext?.flushBuffer()
    }
}
