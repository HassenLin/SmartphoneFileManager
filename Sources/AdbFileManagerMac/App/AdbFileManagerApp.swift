import AFMCore
import AppKit
import SwiftUI

/// ADB File Manager（macOS 原生版）。
///
/// 場景：主視窗（雙窗格檔案管理）＋ 終端機視窗（多分頁）＋ 設定視窗。
/// 全部共用同一個 `AppModel`，所以終端機分頁、書籤、傳輸狀態在視窗之間一致。
@main
struct AdbFileManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("ADB File Manager", id: "main") {
            MainWindowView(app: app)
                .onAppear {
                    app.start()
                    AppearanceMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? "")?.apply()
                    appDelegate.onTerminate = { [app] in app.terminals.closeAll() }
                }
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Device") {
                Button("Refresh") { app.remote.reload() }
                Button("Wireless Connection…") { app.sheet = .connect }
                Button("Apps…") { app.sheet = .appManager }.disabled(app.devices.connection == nil)
                Button("Device Info…") { app.sheet = .deviceInfo }.disabled(app.devices.connection == nil)
                Button("Take Screenshot") { app.takeScreenshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(app.devices.connection == nil)
                Button("Screen Mirroring") { app.startScreenMirror() }.disabled(app.devices.connection == nil)
            }
        }

        Window("ADB Terminal", id: "terminal") {
            TerminalWindowView(app: app)
        }
        .defaultSize(width: 860, height: 520)

        Settings {
            SettingsView(app: app)
        }
    }
}

/// 關掉主視窗即結束 app；結束前關閉終端機的 adb 子行程，不留孤兒行程。
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (@MainActor () -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { onTerminate?() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` 直接執行（沒有 .app 外殼）時也要成為一般前景 app，才有 Dock 圖示與選單列
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
