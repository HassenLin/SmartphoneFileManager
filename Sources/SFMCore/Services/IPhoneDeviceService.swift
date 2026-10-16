import Foundation

/// iPhone 裝置資訊（`ideviceinfo` 預設網域＋battery、disk_usage 網域）
public struct IPhoneDetails: Sendable, Hashable {
    public var name = ""
    /// 機型代號，例如 `iPhone18,2`
    public var productType = ""
    public var modelNumber = ""
    public var region = ""
    public var iosVersion = ""
    public var buildVersion = ""
    public var cpuArchitecture = ""
    public var timeZone = ""
    /// 電量百分比；讀不到為 -1
    public var batteryLevel = -1
    public var isCharging = false
    public var externalPower = false
    public var storage = StorageInfo()
}

/// iPhone 上已安裝的 App（`ideviceinstaller list`）
public struct IPhoneInstalledApp: Identifiable, Sendable, Hashable {
    public let bundleID: String
    public let name: String
    public let version: String
    public var id: String { bundleID }
}

/// iPhone 裝置工具：資訊、重新開機／關機、App 清單／安裝／解除安裝。
///
/// 全部透過 libimobiledevice 的命令列工具（與 `IPhoneFileSource` 相同的 `-u UDID [-n]`）。
/// 不提供截圖：`idevicescreenshot` 需掛載 Developer Disk Image，iOS 17 起改走 CoreDevice 通道，
/// libimobiledevice 無法使用（實測 iOS 27：`Could not start screenshotr service: Invalid service`）。
public struct IPhoneDeviceService: Sendable {
    public let udid: String
    public let network: Bool

    public init(udid: String, network: Bool = false) {
        self.udid = udid
        self.network = network
    }

    private var deviceArguments: [String] { IPhoneFileSource.deviceArguments(udid: udid, network: network) }

    /// 執行某個 libimobiledevice 工具；找不到或結束碼非 0 時丟錯
    private func run(_ tool: String, _ arguments: [String], timeout: Duration? = .seconds(30)) async throws -> ProcessOutput {
        guard let executable = AdbLocator.findExecutable(tool) else {
            throw AdbError.executableNotFound("\(tool) (brew install libimobiledevice ideviceinstaller)")
        }
        let output = try await ProcessRunner.run(executable, deviceArguments + arguments, timeout: timeout)
        guard output.exitCode == 0 else { throw AdbError.commandFailed(exitCode: output.exitCode, output: output.text) }
        return output
    }

    // MARK: 資訊

    public func details() async throws -> IPhoneDetails {
        // 三個網域彼此獨立，平行查詢
        async let general = run("ideviceinfo", [])
        async let battery = run("ideviceinfo", ["-q", "com.apple.mobile.battery"])
        async let disk = run("ideviceinfo", ["-q", "com.apple.disk_usage"])
        return Self.parse(general: Self.keyValues(try await general.lines),
                          battery: Self.keyValues((try? await battery.lines) ?? []),
                          disk: Self.keyValues((try? await disk.lines) ?? []))
    }

    /// `ideviceinfo` 的 `Key: Value` 行；巢狀（縮排）的行略過
    static func keyValues(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines where !line.hasPrefix(" ") {
            guard let colon = line.range(of: ": ") else { continue }
            result[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...])
        }
        return result
    }

    static func parse(general: [String: String], battery: [String: String], disk: [String: String]) -> IPhoneDetails {
        var info = IPhoneDetails()
        info.name = general["DeviceName"] ?? ""
        info.productType = general["ProductType"] ?? ""
        info.modelNumber = general["ModelNumber"] ?? ""
        info.region = general["RegionInfo"] ?? ""
        info.iosVersion = general["ProductVersion"] ?? ""
        info.buildVersion = general["BuildVersion"] ?? ""
        info.cpuArchitecture = general["CPUArchitecture"] ?? ""
        info.timeZone = general["TimeZone"] ?? ""
        info.batteryLevel = battery["BatteryCurrentCapacity"].flatMap(Int.init) ?? -1
        info.isCharging = battery["BatteryIsCharging"] == "true"
        info.externalPower = battery["ExternalConnected"] == "true"
        // 資料分割區：總容量 TotalDataCapacity、可用 AmountDataAvailable（與「設定 → 一般 → 儲存空間」接近）
        let total = disk["TotalDataCapacity"].flatMap(Int64.init) ?? 0
        let free = disk["AmountDataAvailable"].flatMap(Int64.init) ?? 0
        info.storage = StorageInfo(totalBytes: total, usedBytes: max(0, total - free), freeBytes: free)
        return info
    }

    // MARK: 電源

    public func restart() async throws { _ = try await run("idevicediagnostics", ["restart"]) }
    public func shutdown() async throws { _ = try await run("idevicediagnostics", ["shutdown"]) }

    // MARK: App

    public func installedApps(includeSystem: Bool) async throws -> [IPhoneInstalledApp] {
        let output = try await run("ideviceinstaller", [
            "list", includeSystem ? "--all" : "--user", "--xml",
            "-a", "CFBundleIdentifier", "-a", "CFBundleDisplayName", "-a", "CFBundleName", "-a", "CFBundleShortVersionString",
        ], timeout: .seconds(60))
        return try Self.parseApps(output.data)
    }

    static func parseApps(_ data: Data) throws -> [IPhoneInstalledApp] {
        guard let start = data.range(of: Data("<?xml".utf8))?.lowerBound else {
            throw AdbError.unexpectedOutput(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let plist = try PropertyListSerialization.propertyList(from: data[start...], format: nil)
        guard let entries = plist as? [[String: Any]] else { throw AdbError.unexpectedOutput("not an array") }
        return entries.compactMap { entry -> IPhoneInstalledApp? in
            guard let bundle = entry["CFBundleIdentifier"] as? String, !bundle.isEmpty else { return nil }
            let name = (entry["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (entry["CFBundleName"] as? String) ?? bundle
            return IPhoneInstalledApp(bundleID: bundle, name: name,
                                      version: entry["CFBundleShortVersionString"] as? String ?? "")
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 安裝 .ipa（須為已簽給此裝置的套件，例如 ad-hoc／開發簽章）
    public func install(ipa path: String) async throws {
        _ = try await run("ideviceinstaller", ["install", path], timeout: .seconds(600))
    }

    public func uninstall(_ bundleID: String) async throws {
        _ = try await run("ideviceinstaller", ["uninstall", bundleID], timeout: .seconds(120))
    }
}
