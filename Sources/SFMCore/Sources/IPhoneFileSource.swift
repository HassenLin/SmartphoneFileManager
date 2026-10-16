import Foundation

/// iPhone／iPad 的檔案來源，透過 libimobiledevice 的 `afcclient`（AFC 服務）。
///
/// 硬體／系統背景：
/// - macOS 沒有存取 iPhone 檔案系統的公開 API；AFC 是 iTunes／Finder 同步用的服務，
///   根目錄是 `/var/mobile/Media`（DCIM、Downloads、Books、Recordings…），不是整個系統。
/// - 需要 `brew install libimobiledevice`，且 iPhone 已解鎖並按過「信任這台電腦」。
///
/// afcclient 的實測行為（libimobiledevice 1.4.0、iOS 27）：
/// - **錯誤時結束碼仍為 0**，只能從輸出的 `Error: ...` 判斷失敗。
/// - `rm` 不支援遞迴，非空資料夾回 "Directory not empty"，因此由這裡自行逐層刪除。
/// - 沒有 copy；同來源複製交給 `FileTransfer` 經 Mac 暫存區中繼（`nativeCopy = false`）。
/// - `ls -l` 的旗標必須放在 `--` 之後，否則被 afcclient 自己的選項解析器吃掉。
/// - `get -rf DIR LOCALDIR/` 會在 LOCALDIR 底下建立同名資料夾；`put -rf DIR TARGET` 則直接建立 TARGET。
/// - 互動模式（stdin 管線）讀到 EOF 不會結束，所以每個操作都起一個獨立行程。
public struct IPhoneFileSource: FileSource {
    public let udid: String
    public let executable: String

    public init(udid: String, executable: String) {
        self.udid = udid
        self.executable = executable
    }

    public var id: SourceID { .iphone(udid) }
    public var homePath: String { "/" }
    public var capabilities: SourceCapabilities { SourceCapabilities(nativeCopy: false) }

    /// 找 afcclient（Homebrew 預設位置）；未安裝時為 nil
    public static func locateTool(_ name: String = "afcclient") -> String? {
        AdbLocator.findExecutable(name)
    }

    /// 執行一個 afcclient 指令；輸出含 `Error:` 即視為失敗
    @discardableResult
    func run(_ arguments: [String], timeout: Duration? = .seconds(30)) async throws -> [String] {
        let output = try await ProcessRunner.run(executable, ["-u", udid, "--"] + arguments, timeout: timeout)
        let lines = output.lines
        if let error = lines.first(where: { $0.hasPrefix("Error:") || $0.hasPrefix("ERROR:") || $0.hasPrefix("No device found") }) {
            throw AdbError.commandFailed(exitCode: output.exitCode, output: error)
        }
        if output.exitCode != 0 {
            throw AdbError.commandFailed(exitCode: output.exitCode, output: output.text)
        }
        return lines
    }

    // MARK: 瀏覽

    public func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
        let lines: [String]
        do {
            lines = try await run(["ls", "-l", directory])
        } catch AdbError.commandFailed {
            throw AdbError.cannotOpenDirectory(directory)
        }
        return Self.parseLongListing(lines, parent: directory).filter { includeHidden || !$0.isHidden }
    }

    /// 解析 `ls -l`：`drwxr-xr-x    2 mobile mobile    64 20 Sep 2025 00:31:29 名稱（可含空白）`
    /// 時間為 Mac 本地時區（afcclient 以 localtime 格式化）。
    static func parseLongListing(_ lines: [String], parent: String) -> [FileItem] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss"
        let regex = /^([dlbcps-][rwxsStT-]{9})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2}) (.+)$/
        return lines.compactMap { line in
            guard let match = line.firstMatch(of: regex) else { return nil }
            let permissions = String(match.1)
            let name = String(match.4)
            guard name != ".", name != ".." else { return nil }
            return FileItem(path: RemotePath.join(parent, name), name: name,
                            isDirectory: permissions.hasPrefix("d"),
                            size: Int64(match.2) ?? 0,
                            modified: formatter.date(from: String(match.3)),
                            permissions: permissions)
        }
    }

    /// `info` 回傳 JSON（st_ifmt 等）；不存在時丟錯
    func info(_ path: String) async throws -> [String: Any] {
        let text = try await run(["info", path]).joined(separator: "\n")
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdbError.unexpectedOutput(text)
        }
        return object
    }

    public func isDirectory(_ path: String) async throws -> Bool {
        guard let info = try? await info(path) else { return false }
        return info["st_ifmt"] as? String == "S_IFDIR"
    }

    public func exists(_ path: String) async throws -> Bool {
        (try? await info(path)) != nil
    }

    // MARK: 修改

    public func makeDirectory(at path: String) async throws {
        try await run(["mkdir", path])
    }

    public func move(_ path: String, to target: String) async throws {
        try await run(["mv", path, target])
    }

    public func copy(_ path: String, to target: String) async throws {
        throw AdbError.invalidArgument("AFC has no copy; FileTransfer stages through the Mac")
    }

    /// AFC 的 rm 不遞迴：資料夾先刪內容（含隱藏檔）再刪自己
    public func delete(_ path: String) async throws {
        guard RemotePath.normalize(path) != "/" else { throw AdbError.invalidArgument("Refusing to delete /") }
        if try await isDirectory(path) {
            for child in try await list(path, includeHidden: true) {
                try Task.checkCancellation()
                try await delete(child.path)
            }
        }
        try await run(["rm", path])
    }

    // MARK: 傳輸

    /// iPhone → Mac。資料夾：`get -rf` 會在目的資料夾下建立同名資料夾，
    /// 所以先抓到暫存父目錄，再搬到指定的完整路徑（可能是改過名的）。
    public func download(_ path: String, to localURL: URL, expectedSize: Int64?,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if try await isDirectory(path) {
            let staging = localURL.deletingLastPathComponent()
                .appendingPathComponent(".afm-get-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try await run(["get", "-rf", path, staging.path + "/"], timeout: nil)
            try FileManager.default.moveItem(at: staging.appendingPathComponent(RemotePath.name(of: path)), to: localURL)
        } else {
            try await withLocalSizePolling(localURL, expectedSize: expectedSize, onProgress: onProgress) {
                try await run(["get", "-f", path, localURL.path], timeout: nil)
            }
        }
        onProgress(1)
    }

    public func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            throw AdbError.invalidArgument(String(localized: "Local file does not exist: \(localURL.path)"))
        }
        try await run(["put", isDirectory.boolValue ? "-rf" : "-f", localURL.path, path], timeout: nil)
        onProgress(1)
    }

    /// 下載單檔時輪詢本機檔案大小回報進度
    private func withLocalSizePolling(_ localURL: URL, expectedSize: Int64?,
                                      onProgress: @escaping @Sendable (Double) -> Void,
                                      _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            if let expectedSize, expectedSize > 0 {
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(150))
                        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
                        onProgress(min(1, Double(size) / Double(expectedSize)))
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

/// 已連接的 iPhone（`idevice_id -l` + `ideviceinfo -k DeviceName`）
public struct IPhoneDeviceInfo: Identifiable, Hashable, Sendable {
    public let udid: String
    public let name: String
    public var id: String { udid }

    public init(udid: String, name: String) {
        self.udid = udid
        self.name = name
    }

    /// 列出 USB 連接的 iPhone；libimobiledevice 未安裝時回傳空陣列
    public static func list(knownNames: [String: String] = [:]) async -> [IPhoneDeviceInfo] {
        guard let idevice = AdbLocator.findExecutable("idevice_id") else { return [] }
        guard let output = try? await ProcessRunner.run(idevice, ["-l"], timeout: .seconds(10)) else { return [] }
        let udids = output.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var result: [IPhoneDeviceInfo] = []
        for udid in udids {
            if let name = knownNames[udid] {
                result.append(IPhoneDeviceInfo(udid: udid, name: name))
                continue
            }
            var name = "iPhone"
            if let info = AdbLocator.findExecutable("ideviceinfo"),
               let out = try? await ProcessRunner.run(info, ["-u", udid, "-k", "DeviceName"], timeout: .seconds(10)),
               out.exitCode == 0, let first = out.lines.first, !first.isEmpty, !first.hasPrefix("ERROR") {
                name = first
            }
            result.append(IPhoneDeviceInfo(udid: udid, name: name))
        }
        return result
    }
}
