import Foundation

/// `adb devices -l` 的一列。
public struct AdbDeviceInfo: Identifiable, Hashable, Sendable {
    public let serial: String
    /// `device`／`unauthorized`／`offline`／`recovery`…；只有 `device` 可操作
    public let state: String
    public let model: String?
    public let product: String?

    public var id: String { serial }
    public var isReady: Bool { state == "device" }
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }
    /// 無線連線：`ip:port` 或 mDNS 的 `adb-xxx._adb-tls-connect._tcp`
    public var isWireless: Bool { serial.contains(":") || serial.contains("adb-tls-connect") }

    public var displayName: String {
        let name = model?.replacingOccurrences(of: "_", with: " ") ?? serial
        return name == serial ? serial : "\(name) (\(serial))"
    }

    public init(serial: String, state: String, model: String? = nil, product: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
    }

    /// 解析 `adb devices -l` 輸出。第一行必須是 "List of devices attached"，否則視為無裝置
    /// （例如 adb server 剛啟動時印出的 "* daemon started successfully"）。
    public static func parse(_ lines: [String]) -> [AdbDeviceInfo] {
        guard let header = lines.firstIndex(where: { $0.hasPrefix("List of devices attached") }) else { return [] }
        return lines[(header + 1)...].compactMap { line in
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 2 else { return nil }
            // 第 2 欄是狀態；之後的 key:value（product/model/device/transport_id）才是屬性。
            // "no permissions (...)" 這種含空白的狀態只取第一個字，反正都不是 "device"。
            var fields: [String: String] = [:]
            for token in tokens.dropFirst(2) {
                guard let colon = token.firstIndex(of: ":") else { continue }
                fields[String(token[..<colon])] = String(token[token.index(after: colon)...])
            }
            return AdbDeviceInfo(serial: tokens[0], state: tokens[1],
                                 model: fields["model"], product: fields["product"])
        }
    }
}

/// 與 adb 執行檔互動的入口（不綁特定裝置）。值型別、Sendable，可放心跨 Task 傳遞。
public struct AdbClient: Sendable {
    public let executable: String

    public init(executable: String) {
        self.executable = executable
    }

    /// 依使用者設定（內建／自訂／系統 PATH）解析出的 client
    public static var current: AdbClient { AdbClient(executable: AdbLocator.resolve()) }

    @discardableResult
    public func run(_ arguments: [String], check: Bool = false, timeout: Duration? = .seconds(30)) async throws -> ProcessOutput {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AdbError.executableNotFound(executable)
        }
        let output = try await ProcessRunner.run(executable, arguments, timeout: timeout)
        if check, output.exitCode != 0 {
            throw AdbError.commandFailed(exitCode: output.exitCode, output: output.text)
        }
        return output
    }

    public func startServer() async {
        _ = try? await run(["start-server"], timeout: .seconds(20))
    }

    public func devices() async throws -> [AdbDeviceInfo] {
        AdbDeviceInfo.parse(try await run(["devices", "-l"], timeout: .seconds(10)).lines)
    }

    public func version() async throws -> String {
        let output = try await run(["version"], check: true, timeout: .seconds(10))
        guard output.text.localizedCaseInsensitiveContains("Android Debug Bridge") else {
            throw AdbError.unexpectedOutput(output.text)
        }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `adb connect` 失敗時結束碼仍是 0，必須看輸出判斷
    public func connect(host: String, port: String) async throws -> String {
        let text = try await run(["connect", "\(host):\(port.isEmpty ? "5555" : port)"], timeout: .seconds(20)).text
        guard text.contains("connected to") else { throw AdbError.unexpectedOutput(text) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func pair(host: String, port: String, code: String) async throws -> String {
        let output = try await run(["pair", "\(host):\(port)", code], timeout: .seconds(30))
        guard output.text.contains("Successfully paired") else { throw AdbError.unexpectedOutput(output.text) }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func disconnect(serial: String) async throws {
        try await run(["disconnect", serial], timeout: .seconds(10))
    }

    public func device(_ serial: String) -> DeviceConnection {
        DeviceConnection(client: self, serial: serial)
    }
}

/// 綁定單一裝置的 adb 操作（`adb -s <serial> ...`）。
public struct DeviceConnection: Sendable, Hashable {
    public let client: AdbClient
    public let serial: String

    public static func == (lhs: DeviceConnection, rhs: DeviceConnection) -> Bool {
        lhs.serial == rhs.serial && lhs.client.executable == rhs.client.executable
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(serial)
        hasher.combine(client.executable)
    }

    func arguments(_ rest: [String]) -> [String] { ["-s", serial] + rest }

    /// 在裝置上執行一段 sh 指令。**呼叫端負責以 `ShellText.quote` 跳脫路徑。**
    /// 新版 adb（shell protocol v2）會回傳裝置端的結束碼，`check` 才有意義。
    public func shell(_ command: String, check: Bool = false, timeout: Duration? = .seconds(30)) async throws -> [String] {
        try await client.run(arguments(["shell", command]), check: check, timeout: timeout).lines
    }

    public func push(_ localPath: String, to remotePath: String) async throws {
        try await client.run(arguments(["push", localPath, remotePath]), check: true, timeout: nil)
    }

    public func pull(_ remotePath: String, to localPath: String) async throws {
        try await client.run(arguments(["pull", remotePath, localPath]), check: true, timeout: nil)
    }


    /// 在本機安裝 APK（`adb install -r`）
    public func install(localApk: String) async throws -> String {
        let output = try await client.run(arguments(["install", "-r", localApk]), check: true, timeout: nil)
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `adb exec-out <args>` 的二進位 stdout 直接寫入本機檔案（screencap 用）
    public func execOut(_ command: [String], to destination: URL) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let output = try await ProcessRunner.run(
            client.executable, arguments(["exec-out"] + command), timeout: .seconds(30), standardOutput: handle)
        if output.exitCode != 0 {
            try? FileManager.default.removeItem(at: destination)
            throw AdbError.commandFailed(exitCode: output.exitCode, output: output.text)
        }
    }
}
