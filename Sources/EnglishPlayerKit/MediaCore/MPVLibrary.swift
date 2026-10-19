import Darwin
import Foundation

struct MPVEvent {
    var eventID: Int32
    var error: Int32
    var replyUserdata: UInt64
    var data: UnsafeMutableRawPointer?
}

struct MPVEventProperty {
    var name: UnsafePointer<CChar>?
    var format: Int32
    var padding: Int32
    var data: UnsafeMutableRawPointer?
}

struct MPVRenderParam {
    var type: Int32
    var padding: Int32 = 0
    var data: UnsafeMutableRawPointer?
}

struct MPVOpenGLInit {
    var getProc: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?
    var ctx: UnsafeMutableRawPointer?
}

struct MPVOpenGLFBO {
    var fbo: Int32
    var width: Int32
    var height: Int32
    var internalFormat: Int32
}

@_cdecl("englishplayer_gl_get_proc")
func englishplayerGLGetProc(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

/// 动态加载 libmpv。不把播放细节暴露给界面层。
final class MPVLibrary {
    static let formatString: Int32 = 1
    static let formatFlag: Int32 = 3
    static let formatDouble: Int32 = 5
    static let eventNone: Int32 = 0
    static let eventEndFile: Int32 = 7
    static let eventFileLoaded: Int32 = 8
    static let eventPropertyChange: Int32 = 22
    static let endFileError: Int32 = 4

    let handle: UnsafeMutableRawPointer
    let create: @convention(c) () -> OpaquePointer?
    let initialize: @convention(c) (OpaquePointer) -> Int32
    let destroy: @convention(c) (OpaquePointer) -> Void
    let setOptionString: @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    let setPropertyString: @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    let getProperty: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, UnsafeMutableRawPointer?) -> Int32
    let setProperty: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, UnsafeMutableRawPointer?) -> Int32
    let observeProperty: @convention(c) (OpaquePointer, UInt64, UnsafePointer<CChar>, Int32) -> Int32
    let commandFn: @convention(c) (OpaquePointer, UnsafePointer<UnsafePointer<CChar>?>) -> Int32
    let freeMemory: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let waitEvent: @convention(c) (OpaquePointer, Double) -> UnsafeRawPointer
    let setWakeup: @convention(c) (OpaquePointer, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void
    let errorString: @convention(c) (Int32) -> UnsafePointer<CChar>?
    let renderCreate: @convention(c) (UnsafeMutablePointer<OpaquePointer?>, OpaquePointer, UnsafeMutableRawPointer) -> Int32
    let renderFrame: @convention(c) (OpaquePointer, UnsafeMutableRawPointer) -> Int32
    let renderFree: @convention(c) (OpaquePointer) -> Void
    let renderUpdate: @convention(c) (OpaquePointer) -> UInt64
    let renderSetUpdate: @convention(c) (OpaquePointer, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void

    static func openGLInit() -> MPVOpenGLInit {
        MPVOpenGLInit(getProc: englishplayerGLGetProc, ctx: nil)
    }

    static func load() -> MPVLibrary? {
        guard let path = locate() else { return nil }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
            return nil
        }
        return MPVLibrary(handle: handle)
    }

    static func locate() -> String? {
        // 打包后的 .app 把依赖放在 Frameworks，和调试时放在「应用程序支持」的那份分开。
        let inApp = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libmpv.dylib")
        if FileManager.default.fileExists(atPath: inApp.path) {
            return inApp.path
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let bundled = base?.appendingPathComponent("EnglishPlayer/libmpv/libmpv.dylib").path
        if let bundled, FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return nil
    }

    private init?(handle: UnsafeMutableRawPointer) {
        self.handle = handle
        func symbol<T>(_ name: String) -> T? {
            guard let raw = dlsym(handle, name) else { return nil }
            return unsafeBitCast(raw, to: T.self)
        }
        guard let create: @convention(c) () -> OpaquePointer? = symbol("mpv_create"),
              let initialize: @convention(c) (OpaquePointer) -> Int32 = symbol("mpv_initialize"),
              let destroy: @convention(c) (OpaquePointer) -> Void = symbol("mpv_terminate_destroy"),
              let setOptionString: @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32 = symbol("mpv_set_option_string"),
              let setPropertyString: @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32 = symbol("mpv_set_property_string"),
              let getProperty: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, UnsafeMutableRawPointer?) -> Int32 = symbol("mpv_get_property"),
              let setProperty: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, UnsafeMutableRawPointer?) -> Int32 = symbol("mpv_set_property"),
              let observeProperty: @convention(c) (OpaquePointer, UInt64, UnsafePointer<CChar>, Int32) -> Int32 = symbol("mpv_observe_property"),
              let commandFn: @convention(c) (OpaquePointer, UnsafePointer<UnsafePointer<CChar>?>) -> Int32 = symbol("mpv_command"),
              let freeMemory: @convention(c) (UnsafeMutableRawPointer?) -> Void = symbol("mpv_free"),
              let waitEvent: @convention(c) (OpaquePointer, Double) -> UnsafeRawPointer = symbol("mpv_wait_event"),
              let setWakeup: @convention(c) (OpaquePointer, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void = symbol("mpv_set_wakeup_callback"),
              let errorString: @convention(c) (Int32) -> UnsafePointer<CChar>? = symbol("mpv_error_string"),
              let renderCreate: @convention(c) (UnsafeMutablePointer<OpaquePointer?>, OpaquePointer, UnsafeMutableRawPointer) -> Int32 = symbol("mpv_render_context_create"),
              let renderFrame: @convention(c) (OpaquePointer, UnsafeMutableRawPointer) -> Int32 = symbol("mpv_render_context_render"),
              let renderFree: @convention(c) (OpaquePointer) -> Void = symbol("mpv_render_context_free"),
              let renderUpdate: @convention(c) (OpaquePointer) -> UInt64 = symbol("mpv_render_context_update"),
              let renderSetUpdate: @convention(c) (OpaquePointer, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void = symbol("mpv_render_context_set_update_callback")
        else {
            dlclose(handle)
            return nil
        }
        self.create = create
        self.initialize = initialize
        self.destroy = destroy
        self.setOptionString = setOptionString
        self.setPropertyString = setPropertyString
        self.getProperty = getProperty
        self.setProperty = setProperty
        self.observeProperty = observeProperty
        self.commandFn = commandFn
        self.freeMemory = freeMemory
        self.waitEvent = waitEvent
        self.setWakeup = setWakeup
        self.errorString = errorString
        self.renderCreate = renderCreate
        self.renderFrame = renderFrame
        self.renderFree = renderFree
        self.renderUpdate = renderUpdate
        self.renderSetUpdate = renderSetUpdate
    }

    func option(_ handle: OpaquePointer, _ name: String, _ value: String) -> Int32 {
        name.withCString { name in
            value.withCString { value in
                setOptionString(handle, name, value)
            }
        }
    }

    func property(_ handle: OpaquePointer, _ name: String, _ value: String) -> Int32 {
        name.withCString { name in
            value.withCString { value in
                setPropertyString(handle, name, value)
            }
        }
    }

    func command(_ handle: OpaquePointer, _ args: [String]) -> Int32 {
        let owned = args.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        pointers.append(nil)
        return pointers.withUnsafeBufferPointer { buffer in
            commandFn(handle, buffer.baseAddress!)
        }
    }

    func doubleProperty(_ handle: OpaquePointer, _ name: String) -> Double? {
        var value = 0.0
        let status = name.withCString { name in
            withUnsafeMutablePointer(to: &value) { pointer in
                getProperty(handle, name, Self.formatDouble, UnsafeMutableRawPointer(pointer))
            }
        }
        guard status >= 0, value.isFinite else { return nil }
        return value
    }

    func flag(_ handle: OpaquePointer, _ name: String, _ value: Bool) {
        var flag: Int32 = value ? 1 : 0
        _ = name.withCString { name in
            withUnsafeMutablePointer(to: &flag) { pointer in
                setProperty(handle, name, Self.formatFlag, UnsafeMutableRawPointer(pointer))
            }
        }
    }

    func stringProperty(_ handle: OpaquePointer, _ name: String) -> String? {
        var out: UnsafeMutablePointer<CChar>?
        let status = name.withCString { name in
            withUnsafeMutablePointer(to: &out) { pointer in
                getProperty(handle, name, Self.formatString, UnsafeMutableRawPointer(pointer))
            }
        }
        guard status >= 0, let out else { return nil }
        let text = String(cString: out)
        freeMemory(UnsafeMutableRawPointer(out))
        return text
    }

    func describe(_ code: Int32) -> String {
        guard let pointer = errorString(code) else { return "mpv \(code)" }
        let text = String(cString: pointer)
        return text.isEmpty ? "mpv \(code)" : text
    }
}
