import Foundation

/// 啟動 scrcpy 螢幕鏡像。
///
/// 與原版差異：原版會從 GitHub 下載並快取 scrcpy；macOS 上 scrcpy 的標準安裝方式是
/// Homebrew（`brew install scrcpy`），且其相依的 SDL/ffmpeg 動態函式庫由 brew 管理，
/// 自行下載解壓反而容易缺函式庫。所以這版只負責「找到並啟動」，找不到時提示安裝方式。
public enum ScrcpyLauncher {
    public struct Options: Sendable {
        public var maxFps = 60
        /// Mbps；0 = scrcpy 預設
        public var bitrate = 0
        public var turnScreenOff = false
        public var stayAwake = false

        public init() {}

        public static func fromDefaults(_ defaults: UserDefaults = .standard) -> Options {
            var options = Options()
            if defaults.object(forKey: SettingsKey.scrcpyMaxFps) != nil { options.maxFps = defaults.integer(forKey: SettingsKey.scrcpyMaxFps) }
            options.bitrate = defaults.integer(forKey: SettingsKey.scrcpyBitrate)
            options.turnScreenOff = defaults.bool(forKey: SettingsKey.scrcpyTurnScreenOff)
            options.stayAwake = defaults.bool(forKey: SettingsKey.scrcpyStayAwake)
            return options
        }
    }

    public static func locate(defaults: UserDefaults = .standard) -> String? {
        let custom = (defaults.string(forKey: SettingsKey.scrcpyPath) ?? "").trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return FileManager.default.isExecutableFile(atPath: custom) ? custom : nil }
        return AdbLocator.findExecutable("scrcpy")
    }

    static func arguments(serial: String, options: Options) -> [String] {
        var args = ["-s", serial]
        if options.maxFps > 0 { args.append("--max-fps=\(options.maxFps)") }
        if options.bitrate > 0 { args.append("--video-bit-rate=\(options.bitrate)M") }
        if options.turnScreenOff { args.append("--turn-screen-off") }
        if options.stayAwake { args.append("--stay-awake") }
        return args
    }

    /// 啟動後不等待（scrcpy 自己開視窗）。以 `ADB` 環境變數指定我們正在用的 adb，
    /// 避免 scrcpy 用另一版 adb 而把 adb server 重啟。
    public static func launch(executable: String, serial: String, adbPath: String, options: Options) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(serial: serial, options: options)
        var env = ProcessInfo.processInfo.environment
        env["ADB"] = adbPath
        // brew 版 scrcpy 會找 PATH 中的 adb；GUI app 的 PATH 很短，補上 adb 所在目錄
        env["PATH"] = [URL(fileURLWithPath: adbPath).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? ""]
            .joined(separator: ":")
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
