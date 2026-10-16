import Foundation

/// 外部工具的偵測結果（安裝導引用）。
///
/// 偵測規則與實際執行時一致：adb 用 `AdbLocator.resolve()`（依設定的模式），
/// iPhone 工具與 scrcpy 用 `AdbLocator.findExecutable`（PATH + Homebrew）。
public struct ToolReport: Sendable, Equatable {
    /// 實際會使用的 adb 路徑（不一定存在）
    public var adbPath: String
    /// `adb version` 第一行；nil 表示無法執行
    public var adbVersion: String?
    public var adbError: String?
    public var brewPath: String?
    public var afcclientPath: String?
    public var ideviceIDPath: String?
    /// 列出 iPhone 上可分享檔案的 App（Finder「檔案」分頁）；沒有時只能看媒體區
    public var ideviceInstallerPath: String?
    public var scrcpyPath: String?

    public var adbReady: Bool { adbVersion != nil }
    /// iPhone 需要 idevice_id（列裝置）與 afcclient（檔案）兩個工具
    public var iphoneReady: Bool { afcclientPath != nil && ideviceIDPath != nil }
    public var iphoneAppsReady: Bool { ideviceInstallerPath != nil }
    public var scrcpyReady: Bool { scrcpyPath != nil }
}

public enum ToolDetector {
    public static func detect() async -> ToolReport {
        let client = AdbClient.current
        var report = ToolReport(adbPath: client.executable)
        do {
            report.adbVersion = try await client.version().components(separatedBy: "\n").first
        } catch {
            report.adbError = error.localizedDescription
        }
        report.brewPath = AdbLocator.findExecutable("brew")
        report.afcclientPath = AdbLocator.findExecutable("afcclient")
        report.ideviceIDPath = AdbLocator.findExecutable("idevice_id")
        report.ideviceInstallerPath = AdbLocator.findExecutable("ideviceinstaller")
        report.scrcpyPath = ScrcpyLauncher.locate()
        return report
    }
}
