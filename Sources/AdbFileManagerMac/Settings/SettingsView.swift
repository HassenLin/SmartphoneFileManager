import AFMCore
import AppKit
import SwiftUI

/// 外觀（原版的 淺色／深色／跟隨系統）
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 設定視窗（原版 SettingsDialog）。值都存在 UserDefaults，鍵定義於 AFMCore `SettingsKey`。
struct SettingsView: View {
    let app: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(app: app).tabItem { Label("General", systemImage: "gearshape") }
            AdbSettingsView(app: app).tabItem { Label("ADB", systemImage: "cable.connector") }
            ScrcpySettingsView().tabItem { Label("Screen Mirroring", systemImage: "rectangle.on.rectangle") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettingsView: View {
    let app: AppModel
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(SettingsKey.showHiddenFiles) private var showHidden = true
    @AppStorage(SettingsKey.defaultExportDirectory) private var exportDirectory = ""

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag(AppearanceMode.system.rawValue)
                Text("Light").tag(AppearanceMode.light.rawValue)
                Text("Dark").tag(AppearanceMode.dark.rawValue)
            }
            .onChange(of: appearance) { _, value in AppearanceMode(rawValue: value)?.apply() }
            Toggle("Show hidden files", isOn: $showHidden)
                .onChange(of: showHidden) { _, _ in
                    app.remote.reload()
                    app.local.reload()
                }
            Picker("Default sort order", selection: Binding(get: { app.remote.sortType }, set: { app.remote.sortType = $0 })) {
                ForEach(SortType.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Mac start folder") {
                HStack {
                    Text(exportDirectory.isEmpty ? String(localized: "Downloads") : exportDirectory)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { exportDirectory = url.path }
                    }
                }
            }
            Text("Language follows the macOS system setting (English / 繁體中文).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AdbSettingsView: View {
    let app: AppModel
    @AppStorage(SettingsKey.adbMode) private var mode = AdbMode.bundled.rawValue
    @AppStorage(SettingsKey.customAdbPath) private var customPath = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Picker("ADB executable", selection: $mode) {
                Text("Bundled (recommended)").tag(AdbMode.bundled.rawValue)
                Text("Custom path").tag(AdbMode.custom.rawValue)
                Text("System (PATH / Homebrew / Android SDK)").tag(AdbMode.system.rawValue)
            }
            .pickerStyle(.radioGroup)
            if mode == AdbMode.custom.rawValue {
                HStack {
                    TextField("Path to adb", text: $customPath)
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { customPath = url.path }
                    }
                }
            }
            LabeledContent("In use") {
                Text(AdbClient.current.executable).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            HStack {
                Button("Test") { test() }.disabled(testing)
                Button("Restart ADB Server") { app.devices.restartServer() }
                if testing { ProgressView().controlSize(.small) }
            }
            if let testResult {
                Text(testResult).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        testing = true
        Task {
            defer { testing = false }
            do { testResult = try await AdbClient.current.version() }
            catch { testResult = error.localizedDescription }
        }
    }
}

private struct ScrcpySettingsView: View {
    @AppStorage(SettingsKey.scrcpyPath) private var path = ""
    @AppStorage(SettingsKey.scrcpyMaxFps) private var maxFps = 60
    @AppStorage(SettingsKey.scrcpyBitrate) private var bitrate = 0
    @AppStorage(SettingsKey.scrcpyTurnScreenOff) private var turnScreenOff = false
    @AppStorage(SettingsKey.scrcpyStayAwake) private var stayAwake = false

    var body: some View {
        Form {
            HStack {
                TextField("scrcpy path (empty = auto-detect)", text: $path)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
            LabeledContent("Detected") {
                Text(ScrcpyLauncher.locate() ?? String(localized: "Not found — brew install scrcpy"))
                    .textSelection(.enabled)
            }
            Stepper("Max FPS: \(maxFps == 0 ? String(localized: "unlimited") : String(maxFps))", value: $maxFps, in: 0...120, step: 10)
            Stepper("Bitrate: \(bitrate == 0 ? String(localized: "default") : "\(bitrate) Mbps")", value: $bitrate, in: 0...64, step: 2)
            Toggle("Turn device screen off while mirroring", isOn: $turnScreenOff)
            Toggle("Keep device awake", isOn: $stayAwake)
        }
        .formStyle(.grouped)
    }
}
