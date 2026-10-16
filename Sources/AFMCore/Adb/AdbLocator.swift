import Foundation

/// adb 執行檔來源（對應原版 `AdbMode`）。
public enum AdbMode: String, CaseIterable, Sendable, Identifiable {
    /// app bundle 內附的 adb（`Contents/Resources/bin/adb`，由 make-app.sh 放入）
    case bundled
    /// 使用者指定的路徑
    case custom
    /// 從 PATH 與常見安裝位置搜尋
    case system

    public var id: String { rawValue }
}

/// 解析實際要執行的 adb 路徑。
///
/// GUI app 從 Finder／Dock 啟動時拿不到 shell 的 PATH（只有 `/usr/bin:/bin:...`），
/// 所以「系統」模式除了 PATH 之外還會找 Homebrew 與 Android SDK 的慣用位置。
/// 任何模式找不到時都退回內建 adb，再不行就回傳系統搜尋結果，讓錯誤訊息顯示實際路徑。
public enum AdbLocator {
    public static func resolve(defaults: UserDefaults = .standard) -> String {
        let mode = AdbMode(rawValue: defaults.string(forKey: SettingsKey.adbMode) ?? "") ?? .bundled
        switch mode {
        case .bundled:
            return bundledPath() ?? systemPath() ?? "/usr/local/bin/adb"
        case .custom:
            let custom = (defaults.string(forKey: SettingsKey.customAdbPath) ?? "").trimmingCharacters(in: .whitespaces)
            if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) { return custom }
            return bundledPath() ?? systemPath() ?? custom
        case .system:
            return systemPath() ?? bundledPath() ?? "/usr/local/bin/adb"
        }
    }

    /// 內附 adb。`swift run` 直接執行（沒有 .app 外殼）時不存在，回傳 nil。
    public static func bundledPath() -> String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/adb"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    public static func systemPath() -> String? {
        findExecutable("adb", extraDirectories: androidSdkDirectories())
    }

    static func androidSdkDirectories() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], "\(home)/Library/Android/sdk"]
            .compactMap { $0 }
            .map { "\($0)/platform-tools" }
    }

    /// 在 PATH + Homebrew + 額外目錄中尋找可執行檔（scrcpy 也用這個）
    public static func findExecutable(_ name: String, extraDirectories: [String] = []) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathDirs + ["/opt/homebrew/bin", "/usr/local/bin"] + extraDirectories
        var seen = Set<String>()
        for dir in candidates where seen.insert(dir).inserted {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

/// UserDefaults 鍵集中定義。UI 的 `@AppStorage` 與 core 的讀取共用同一組字串。
public enum SettingsKey {
    public static let adbMode = "adbMode"
    public static let customAdbPath = "customAdbPath"
    public static let showHiddenFiles = "showHiddenFiles"
    public static let defaultSortType = "defaultSortType"
    public static let defaultExportDirectory = "defaultExportDir"
    public static let localPaneCollapsed = "localPaneCollapsed"
    public static let appearance = "appearance"
    public static let scrcpyPath = "scrcpyCustomPath"
    public static let scrcpyMaxFps = "scrcpyMaxFps"
    public static let scrcpyBitrate = "scrcpyBitrate"
    public static let scrcpyTurnScreenOff = "scrcpyTurnScreenOff"
    public static let scrcpyStayAwake = "scrcpyStayAwake"
}
