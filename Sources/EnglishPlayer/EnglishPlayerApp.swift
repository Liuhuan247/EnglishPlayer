import AppKit
import EnglishPlayerKit
import SwiftUI

@main
struct EnglishPlayerApp: App {
    @StateObject private var model = AppModel.live()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            PlayerCommands(model: model)
        }

        Window("设置", id: "settings") {
            SettingsWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 720, height: 640)
        .windowResizability(.contentMinSize)

        Window("播放列表", id: "playlist") {
            PlaylistWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)

        Window("百度网盘", id: "netdisk") {
            NetdiskWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 860, height: 640)
        .windowResizability(.contentMinSize)
    }
}
