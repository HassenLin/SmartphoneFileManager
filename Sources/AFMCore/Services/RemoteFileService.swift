import Foundation

/// 裝置端檔案操作（原版 `AdbFileOperations` 的檔案部分）。
///
/// 無狀態值型別：每次操作都明確帶入路徑，不像原版以「目前目錄」隱含狀態。
/// 路徑一律為絕對路徑，送進 `sh` 之前一律經 `ShellText.quote`。
public struct RemoteFileService: Sendable {
    public let device: DeviceConnection

    public init(device: DeviceConnection) {
        self.device = device
    }

    private func q(_ value: String) -> String { ShellText.quote(value) }

    // MARK: 瀏覽

    /// 列出目錄。`cd` 失敗（不存在／無權限）時丟 `cannotOpenDirectory`，
    /// 而不是像原版一樣默默回傳空清單。
    public func list(_ directory: String, includeHidden: Bool) async throws -> [RemoteFile] {
        // 萬用字元：`*` 不含隱藏檔；`.[!.]*` 與 `..?*` 補上隱藏檔但排除 `.`、`..`。
        // 沒有符合時 sh 會把字面字串交給 stat，stat 失敗的訊息被導到 /dev/null。
        let globs = includeHidden ? "* .[!.]* ..?*" : "*"
        let marker = "__AFM_CD_FAILED__"
        let command = "cd \(q(directory)) 2>/dev/null || { echo \(marker); exit 1; }; "
            + "stat -L -c \(q(StatParser.format)) \(globs) 2>/dev/null"
        let lines = try await device.shell(command)
        if lines.contains(marker) { throw AdbError.cannotOpenDirectory(directory) }
        return StatParser.parse(lines, parent: directory)
    }

    /// 遞迴搜尋（檔名不分大小寫包含 `query`）
    public func search(in directory: String, query: String, maxDepth: Int = 4) async throws -> [RemoteFile] {
        let command = "find \(q(directory)) -maxdepth \(maxDepth) -iname \(q("*\(query)*")) "
            + "-exec stat -L -c \(q(StatParser.format)) {} + 2>/dev/null"
        return StatParser.parse(try await device.shell(command, timeout: .seconds(60)), parent: nil)
    }

    public func isDirectory(_ path: String) async throws -> Bool {
        try await device.shell("cd \(q(path)) 2>/dev/null && echo OK").contains("OK")
    }

    // MARK: 修改

    public func delete(_ path: String) async throws {
        guard RemotePath.normalize(path) != "/" else { throw AdbError.invalidArgument("Refusing to delete /") }
        _ = try await device.shell("rm -rf -- \(q(path))", check: true, timeout: .seconds(120))
    }

    public func rename(_ path: String, to newName: String) async throws {
        try Self.validateName(newName)
        let target = RemotePath.join(RemotePath.parent(of: path), newName)
        _ = try await device.shell("mv -- \(q(path)) \(q(target))", check: true)
    }

    public func makeDirectory(in directory: String, name: String) async throws {
        try Self.validateName(name)
        _ = try await device.shell("mkdir -p -- \(q(RemotePath.join(directory, name)))", check: true)
    }

    /// 建立新檔：內容先寫本機暫存檔再 push（避免把任意內容塞進 shell 指令）
    public func createFile(in directory: String, name: String, contents: Data) async throws {
        try Self.validateName(name)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("afm-create-\(UUID().uuidString)")
        try contents.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await device.push(temp.path, to: RemotePath.join(directory, name))
    }

    /// `mode` 只接受 3～4 位八進位（`755`、`0644`），杜絕被拼進 shell 的任意字串
    public func changeMode(_ path: String, mode: String) async throws {
        guard mode.range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) != nil else {
            throw AdbError.invalidArgument(String(localized: "Invalid permission mode: \(mode)"))
        }
        _ = try await device.shell("chmod \(mode) -- \(q(path))", check: true)
    }

    public func copy(_ path: String, toDirectory directory: String) async throws {
        _ = try await device.shell("cp -r -- \(q(path)) \(q(directory))", check: true, timeout: nil)
    }

    public func move(_ path: String, toDirectory directory: String) async throws {
        _ = try await device.shell("mv -- \(q(path)) \(q(directory))", check: true, timeout: nil)
    }

    /// 安裝裝置上的 APK（`pm install`）；本機 APK 用 `DeviceConnection.install(localApk:)`
    public func installRemoteApk(_ path: String) async throws -> String {
        let output = try await device.shell("pm install -r \(q(path))", check: true, timeout: nil)
        return output.joined(separator: "\n")
    }

    // MARK: 傳輸

    /// 上傳（本機 → 裝置）。`remotePath` 是目的地完整路徑（含檔名）。
    ///
    /// 進度：原版解析 `adb push -p` 的 `[ 42%]`，但新版 adb 已把 `-p` 當成相容旗標
    /// 靜默忽略、非 TTY 下也不印進度列，所以改為每 0.5 秒 `stat` 一次遠端檔案大小。
    /// 目錄交給 `adb push` 一次處理，進度為不確定（不回報）。
    public func upload(_ localURL: URL, to remotePath: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            throw AdbError.invalidArgument(String(localized: "Local file does not exist: \(localURL.path)"))
        }
        let total = isDirectory.boolValue ? 0 : (LocalFile(url: localURL).size)
        let device = self.device
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await device.push(localURL.path, to: remotePath) }
            if total > 0 {
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(500))
                        // 輪詢失敗（逾時等）不影響傳輸本身，略過這一輪即可
                        let line = try? await device.shell("stat -c %s \(ShellText.quote(remotePath)) 2>/dev/null",
                                                           timeout: .seconds(5)).first
                        if let size = line.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }) {
                            onProgress(min(1, Double(size) / Double(total)))
                        }
                    }
                }
            }
            try await group.next()   // 先完成的一定是 push
            group.cancelAll()
        }
        onProgress(1)
    }

    /// 下載（裝置 → 本機）。`adb pull` 沒有進度輸出，改為輪詢本機檔案大小
    /// （與原版 `pullWithProgress` 相同手法）；`expectedSize` 未知（目錄）時不回報進度。
    public func download(_ remotePath: String, to localURL: URL, expectedSize: Int64?,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let device = self.device
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await device.pull(remotePath, to: localURL.path) }
            if let expectedSize, expectedSize > 0 {
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(150))
                        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
                        onProgress(min(1, Double(size) / Double(expectedSize)))
                    }
                }
            }
            // 第一個完成的一定是 pull（輪詢迴圈不會自己結束）；拿到後取消輪詢
            try await group.next()
            group.cancelAll()
        }
        onProgress(1)
    }


    /// 檔名不得含 `/`、不得為 `.`/`..`/空字串
    public static func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !name.contains("/") else {
            throw AdbError.invalidArgument(String(localized: "Invalid file name: \(name)"))
        }
    }
}
