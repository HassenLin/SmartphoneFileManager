import AppKit
import SFMCore
import SwiftUI

/// 安裝導引的主題
enum SetupTopic: String, CaseIterable, Identifiable {
    case android, iphone, scrcpy

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .android: return "Android (adb)"
        case .iphone: return "iPhone"
        case .scrcpy: return "Screen Mirroring"
        }
    }
}

/// 官方下載與說明連結（集中一處，連結失效時只改這裡）
enum SetupLinks {
    static let platformTools = URL(string: "https://developer.android.com/tools/releases/platform-tools")!
    static let platformToolsZip = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
    static let developerOptions = URL(string: "https://developer.android.com/studio/debug/dev-options")!
    static let homebrew = URL(string: "https://brew.sh")!
    static let libimobiledevice = URL(string: "https://libimobiledevice.org")!
    static let scrcpy = URL(string: "https://github.com/Genymobile/scrcpy")!
}

/// 安裝指令
enum SetupCommands {
    static let homebrew = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
    static let adb = "brew install --cask android-platform-tools"
    static let iphone = "brew install libimobiledevice ideviceinstaller"
    static let scrcpy = "brew install scrcpy"
}

/// 安裝導引：偵測 adb／Homebrew／libimobiledevice／scrcpy，缺少時提供步驟、官方連結與一鍵安裝指令。
struct SetupGuideView: View {
    let app: AppModel
    @State var topic: SetupTopic
    @State private var report: ToolReport?
    @State private var checking = false
    @AppStorage(SettingsKey.adbMode) private var adbMode = AdbMode.bundled.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Setup Guide").font(.title2.bold())
                Spacer()
                Picker("", selection: $topic) {
                    ForEach(SetupTopic.allCases) { topic in
                        Label {
                            Text(topic.title)
                        } icon: {
                            Image(systemName: isReady(topic) ? "checkmark.circle.fill" : "exclamationmark.circle")
                        }
                        .tag(topic)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let report {
                        switch topic {
                        case .android: androidGuide(report)
                        case .iphone: iphoneGuide(report)
                        case .scrcpy: scrcpyGuide(report)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Check Again") { check() }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 660, height: 640)
        .task { check() }
    }

    private func isReady(_ topic: SetupTopic) -> Bool {
        guard let report else { return false }
        switch topic {
        case .android: return report.adbReady
        case .iphone: return report.iphoneReady && report.iphoneAppsReady
        case .scrcpy: return report.scrcpyReady
        }
    }

    private func check() {
        checking = true
        Task {
            defer { checking = false }
            report = await ToolDetector.detect()
            await app.devices.refresh()
            app.refreshSources()
        }
    }

    // MARK: Android

    @ViewBuilder
    private func androidGuide(_ report: ToolReport) -> some View {
        StatusRow(ready: report.adbReady,
                  readyText: String(localized: "adb is ready: \(report.adbVersion ?? "")"),
                  missingText: String(localized: "adb cannot be run: \(report.adbError ?? "")"),
                  detail: report.adbPath)

        if !report.adbReady {
            GuideSection(title: "Option 1 — Use the bundled adb (recommended)") {
                Text("This app ships with Google's adb. Switch back to it if Settings points somewhere else.")
                if AdbLocator.bundledPath() != nil {
                    Button("Use Bundled adb") {
                        adbMode = AdbMode.bundled.rawValue
                        app.devices.restartServer()
                        check()
                    }
                    .disabled(adbMode == AdbMode.bundled.rawValue)
                } else {
                    Text("The bundled adb is missing from this build. Rebuild with tools/make-app.sh, or use option 2 or 3.")
                        .foregroundStyle(.orange)
                }
            }
            GuideSection(title: "Option 2 — Install with Homebrew") {
                homebrewPrerequisite(report)
                CommandBox(command: SetupCommands.adb)
                Text("Then choose Settings → ADB → System.").foregroundStyle(.secondary)
            }
            GuideSection(title: "Option 3 — Download Android SDK Platform-Tools") {
                Text("Download the official zip from Google, unzip it to ~/Library/Android/sdk/ (so adb is at ~/Library/Android/sdk/platform-tools/adb), then choose Settings → ADB → System. Any other folder works with Settings → ADB → Custom path.")
                HStack {
                    Link(destination: SetupLinks.platformToolsZip) { Label("Download Platform-Tools (macOS)", systemImage: "arrow.down.circle") }
                    Link(destination: SetupLinks.platformTools) { Label("Release page", systemImage: "safari") }
                }
            }
        }

        GuideSection(title: "On the Android phone") {
            NumberedSteps(steps: [
                String(localized: "Settings → About phone → tap “Build number” 7 times to enable Developer options."),
                String(localized: "Settings → System → Developer options → turn on “USB debugging”."),
                String(localized: "Connect by USB and tap “Allow” on the “Allow USB debugging?” prompt (tick “Always allow from this computer”)."),
                String(localized: "For Wi-Fi: turn on “Wireless debugging” and use the Wireless button in the toolbar."),
            ])
            Link(destination: SetupLinks.developerOptions) { Label("Android: configure developer options", systemImage: "safari") }
        }
    }

    // MARK: iPhone

    @ViewBuilder
    private func iphoneGuide(_ report: ToolReport) -> some View {
        StatusRow(ready: report.iphoneReady && report.iphoneAppsReady,
                  readyText: String(localized: "libimobiledevice and ideviceinstaller are installed"),
                  missingText: report.iphoneReady
                      ? String(localized: "ideviceinstaller is missing — Media works, but the Apps folder (app documents) can't be listed")
                      : String(localized: "libimobiledevice is not installed"),
                  detail: report.afcclientPath ?? "")

        if !(report.iphoneReady && report.iphoneAppsReady) {
            GuideSection(title: "Install libimobiledevice") {
                Text("macOS has no public API for iPhone files. This app uses the open-source libimobiledevice (the same AFC services Finder uses): “Media” shows DCIM, Downloads, Books…; “Apps” shows the apps that share documents, like the Files tab in Finder.")
                homebrewPrerequisite(report)
                CommandBox(command: SetupCommands.iphone)
                Link(destination: SetupLinks.libimobiledevice) { Label("libimobiledevice.org", systemImage: "safari") }
            }
        }

        GuideSection(title: "On the iPhone") {
            NumberedSteps(steps: [
                String(localized: "Connect the iPhone by USB and unlock it."),
                String(localized: "Tap “Trust” on “Trust This Computer?” and enter the passcode."),
                String(localized: "Choose the iPhone from a pane's source button."),
            ])
            Text("Accessible: Media (DCIM, Downloads, Books, Recordings…) and the Documents folder of apps that enable file sharing. Not accessible: the system, iCloud Drive, or private data of other apps.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: scrcpy

    @ViewBuilder
    private func scrcpyGuide(_ report: ToolReport) -> some View {
        StatusRow(ready: report.scrcpyReady,
                  readyText: String(localized: "scrcpy is installed"),
                  missingText: String(localized: "scrcpy is not installed (only needed for screen mirroring)"),
                  detail: report.scrcpyPath ?? "")
        if !report.scrcpyReady {
            GuideSection(title: "Install scrcpy") {
                homebrewPrerequisite(report)
                CommandBox(command: SetupCommands.scrcpy)
                Text("Or set its path in Settings → Screen Mirroring.").foregroundStyle(.secondary)
                Link(destination: SetupLinks.scrcpy) { Label("scrcpy on GitHub", systemImage: "safari") }
            }
        }
    }

    /// Homebrew 不存在時先提示安裝它
    @ViewBuilder
    private func homebrewPrerequisite(_ report: ToolReport) -> some View {
        if report.brewPath == nil {
            VStack(alignment: .leading, spacing: 6) {
                Label("Homebrew is not installed. Install it first:", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                CommandBox(command: SetupCommands.homebrew)
                Link(destination: SetupLinks.homebrew) { Label("brew.sh", systemImage: "safari") }
            }
        }
    }
}

// MARK: - 元件

private struct StatusRow: View {
    let ready: Bool
    let readyText: String
    let missingText: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(ready ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(ready ? readyText : missingText).font(.headline).textSelection(.enabled)
                if !detail.isEmpty {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((ready ? Color.green : Color.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct GuideSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

private struct NumberedSteps: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(step)
                }
            }
        }
    }
}

/// 指令框：拷貝或直接在「終端機」執行
struct CommandBox: View {
    let command: String

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .help("Copy Command")
            Button("Run in Terminal") { Self.runInTerminal(command) }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 寫成 .command 暫存檔交給「終端機」開啟：使用者看得到完整輸出，也能輸入 sudo 密碼。
    /// 不在 app 內背景執行——安裝需要互動（密碼、確認），且使用者應清楚看到執行了什麼。
    static func runInTerminal(_ command: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sfm-setup-\(UUID().uuidString.prefix(8)).command")
        let script = """
        #!/bin/bash
        echo "$ \(command)"
        \(command)
        echo
        read -r -p "Done. Press Return to close… "
        """
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }
}
