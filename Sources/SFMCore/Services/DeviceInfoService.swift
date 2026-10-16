import Foundation

public enum RebootMode: String, CaseIterable, Identifiable, Sendable {
    case normal, recovery, bootloader

    public var id: String { rawValue }
    var argument: String? { self == .normal ? nil : rawValue }
}

/// 電池資訊。狀態以 Android `BatteryManager` 常數保存，顯示文字由 UI 層決定（才能多語系）。
public struct BatteryInfo: Sendable, Hashable {
    public var level = -1
    public var scale = 100
    public var temperatureCelsius: Double = 0
    public var voltageMillivolts = 0
    /// BATTERY_STATUS_*：2 充電中、3 放電中、4 未充電、5 已充滿
    public var status = 1
    /// BATTERY_HEALTH_*：2 良好、3 過熱、4 損壞、5 過壓、6 故障、7 過冷
    public var health = 1
    public var acPowered = false
    public var usbPowered = false
    public var wirelessPowered = false

    public var percentage: Int { scale > 0 && level >= 0 ? level * 100 / scale : level }
}

public struct StorageInfo: Sendable, Hashable {
    public var totalBytes: Int64 = 0
    public var usedBytes: Int64 = 0
    public var freeBytes: Int64 = 0

    public var usedFraction: Double { totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0 }
}

public struct DeviceDetails: Sendable, Hashable {
    public var model = ""
    public var manufacturer = ""
    public var brand = ""
    public var deviceName = ""
    public var androidVersion = ""
    public var sdkInt = 0
    public var abi = ""
    public var screenSize = ""
    public var density = ""
    public var battery = BatteryInfo()
    public var storage = StorageInfo()
    public var isRooted = false
}

/// 裝置資訊、重新開機、截圖、寫入剪貼簿
public struct DeviceInfoService: Sendable {
    public let device: DeviceConnection

    public init(device: DeviceConnection) {
        self.device = device
    }

    public func details() async throws -> DeviceDetails {
        // 各指令彼此獨立，平行執行縮短等待（原版是逐一呼叫）
        async let propLines = device.shell("getprop")
        async let sizeLines = device.shell("wm size")
        async let densityLines = device.shell("wm density")
        async let batteryLines = device.shell("dumpsys battery")
        async let dfLines = device.shell("df -k /data")
        async let suLines = device.shell("which su")

        var info = DeviceDetails()
        let props = Self.parseProps(try await propLines)
        info.model = props["ro.product.model"] ?? ""
        info.manufacturer = props["ro.product.manufacturer"] ?? ""
        info.brand = props["ro.product.brand"] ?? ""
        info.deviceName = props["ro.product.name"] ?? ""
        info.androidVersion = props["ro.build.version.release"] ?? ""
        info.sdkInt = Int(props["ro.build.version.sdk"] ?? "") ?? 0
        info.abi = props["ro.product.cpu.abi"] ?? ""
        info.screenSize = Self.lastValue(try await sizeLines)
        info.density = Self.lastValue(try await densityLines)
        info.battery = Self.parseBattery(try await batteryLines)
        info.storage = Self.parseDf(try await dfLines)
        info.isRooted = (try await suLines).contains { $0.contains("/su") }
        return info
    }

    static func parseProps(_ lines: [String]) -> [String: String] {
        var props: [String: String] = [:]
        let regex = /\[(.*?)\]:\s*\[(.*?)\]/
        for line in lines {
            if let match = line.firstMatch(of: regex) { props[String(match.1)] = String(match.2) }
        }
        return props
    }

    /// `wm size` 可能同時有 "Physical size" 與 "Override size"，取最後一個（實際生效值）
    static func lastValue(_ lines: [String]) -> String {
        lines.last { $0.contains(":") }.map { String($0[$0.index(after: $0.firstIndex(of: ":")!)...]).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static func parseBattery(_ lines: [String]) -> BatteryInfo {
        var battery = BatteryInfo()
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon]
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "level": battery.level = Int(value) ?? -1
            case "scale": battery.scale = Int(value) ?? 100
            case "temperature": battery.temperatureCelsius = (Double(value) ?? 0) / 10
            case "voltage": battery.voltageMillivolts = Int(value) ?? 0
            case "status": battery.status = Int(value) ?? 1
            case "health": battery.health = Int(value) ?? 1
            case "AC powered": battery.acPowered = value == "true"
            case "USB powered": battery.usbPowered = value == "true"
            case "Wireless powered": battery.wirelessPowered = value == "true"
            default: break
            }
        }
        return battery
    }

    static func parseDf(_ lines: [String]) -> StorageInfo {
        guard lines.count >= 2 else { return StorageInfo() }
        let fields = lines[1].split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4 else { return StorageInfo() }
        func kb(_ index: Int) -> Int64 { (Int64(fields[index]) ?? 0) * 1024 }
        return StorageInfo(totalBytes: kb(1), usedBytes: kb(2), freeBytes: kb(3))
    }

    public func reboot(_ mode: RebootMode) async throws {
        // 裝置重開時 adb 連線會中斷、結束碼不可靠，所以不檢查
        _ = try await device.shell(["reboot", mode.argument].compactMap { $0 }.joined(separator: " "), timeout: .seconds(15))
    }

    public func screenshot(to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await device.execOut(["screencap", "-p"], to: destination)
    }
}
