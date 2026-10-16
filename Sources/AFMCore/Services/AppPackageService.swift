import Foundation

/// 已安裝 App 的摘要。
///
/// 與原版差異：原版把 APK 的 `AndroidManifest.xml` + `resources.arsc` 拉回本機，
/// 用 Java apk-parser 解出 App 名稱與圖示。Swift 沒有對應的成熟套件、自寫 AXML／ARSC
/// 解析器維護成本過高，因此這版只顯示套件名稱，版本資訊改由 `dumpsys package` 隨需載入。
public struct AppPackage: Identifiable, Hashable, Sendable {
    public let packageName: String
    public var isSystem: Bool
    public var isDisabled: Bool

    public var id: String { packageName }

    public init(packageName: String, isSystem: Bool, isDisabled: Bool) {
        self.packageName = packageName
        self.isSystem = isSystem
        self.isDisabled = isDisabled
    }
}

/// `dumpsys package <pkg>` 解析出的細節
public struct AppPackageDetails: Sendable, Hashable {
    public var versionName: String?
    public var versionCode: String?
    public var firstInstallTime: String?
    public var lastUpdateTime: String?
    public var apkPath: String?
    public var targetSdk: String?
}

/// App 管理（原版 `AdbFileOperations` 的 App 部分）
public struct AppPackageService: Sendable {
    public let device: DeviceConnection

    public init(device: DeviceConnection) {
        self.device = device
    }

    /// 套件名稱只允許 Java 套件命名字元，杜絕被拼進 shell 的任意字串
    static func validate(_ packageName: String) throws -> String {
        guard packageName.range(of: #"^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$"#, options: .regularExpression) != nil else {
            throw AdbError.invalidArgument(String(localized: "Invalid package name: \(packageName)"))
        }
        return packageName
    }

    static func parsePackages(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("package:") else { return nil }
            let name = String(trimmed.dropFirst("package:".count))
            return name.isEmpty ? nil : name
        }
    }

    /// 目前使用者（多使用者／工作設定檔裝置）的套件清單
    public func listPackages(includeSystem: Bool) async throws -> [AppPackage] {
        let user = try await currentUser()
        let third = Set(Self.parsePackages(try await device.shell("pm list packages -3 --user \(user)", check: true)))
        let disabled = Set(Self.parsePackages(try await device.shell("pm list packages -d --user \(user)")))
        var names = third
        if includeSystem {
            names.formUnion(Self.parsePackages(try await device.shell("pm list packages -s --user \(user)", check: true)))
        }
        return names.sorted().map { AppPackage(packageName: $0, isSystem: !third.contains($0), isDisabled: disabled.contains($0)) }
    }

    public func currentUser() async throws -> Int {
        let lines = try await device.shell("am get-current-user")
        return lines.lazy.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.first ?? 0
    }

    public func details(_ packageName: String) async throws -> AppPackageDetails {
        let lines = try await device.shell("dumpsys package \(try Self.validate(packageName))", timeout: .seconds(20))
        var details = AppPackageDetails()
        func value(_ line: String, _ key: String) -> String? {
            guard let range = line.range(of: key + "=") else { return nil }
            return line[range.upperBound...].split(separator: " ").first.map(String.init)
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if details.versionName == nil { details.versionName = value(line, "versionName") }
            if details.versionCode == nil { details.versionCode = value(line, "versionCode") }
            if details.targetSdk == nil { details.targetSdk = value(line, "targetSdk") }
            if details.apkPath == nil { details.apkPath = value(line, "codePath") }
            if line.hasPrefix("firstInstallTime=") { details.firstInstallTime = String(line.dropFirst("firstInstallTime=".count)) }
            if line.hasPrefix("lastUpdateTime=") { details.lastUpdateTime = String(line.dropFirst("lastUpdateTime=".count)) }
        }
        return details
    }

    /// 主 APK 路徑（split APK 只取 base，與原版相同）
    public func apkPath(_ packageName: String) async throws -> String {
        let lines = try await device.shell("pm path \(try Self.validate(packageName))")
        guard let path = Self.parsePackages(lines).first(where: { $0.hasSuffix("base.apk") }) ?? Self.parsePackages(lines).first else {
            throw AdbError.unexpectedOutput(lines.joined(separator: "\n"))
        }
        return path
    }

    public func backupApk(_ packageName: String, to destination: URL) async throws {
        let path = try await apkPath(packageName)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await device.pull(path, to: destination.path)
    }

    public func uninstall(_ packageName: String) async throws {
        let output = try await device.shell("pm uninstall \(try Self.validate(packageName))", check: true)
        guard output.contains(where: { $0.contains("Success") }) else {
            throw AdbError.unexpectedOutput(output.joined(separator: "\n"))
        }
    }

    public func launch(_ packageName: String) async throws {
        _ = try await device.shell("monkey -p \(try Self.validate(packageName)) -c android.intent.category.LAUNCHER 1")
    }

    public func forceStop(_ packageName: String) async throws {
        _ = try await device.shell("am force-stop \(try Self.validate(packageName))", check: true)
    }

    public func clearData(_ packageName: String) async throws {
        _ = try await device.shell("pm clear \(try Self.validate(packageName))", check: true)
    }

    public func setEnabled(_ packageName: String, enabled: Bool) async throws {
        let action = enabled ? "enable" : "disable-user"
        _ = try await device.shell("pm \(action) \(try Self.validate(packageName))", check: true)
    }
}
