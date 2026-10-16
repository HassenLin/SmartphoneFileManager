import Foundation

/// Android 裝置的檔案來源（原版 `AdbFileOperations` 的檔案部分）。
///
/// 無狀態值型別：每次操作都明確帶入絕對路徑，送進裝置端 `sh` 之前一律經 `ShellText.quote`。
public struct AndroidFileSource: FileSource {
    public let device: DeviceConnection

    public init(device: DeviceConnection) {
        self.device = device
    }

    public var id: SourceID { .android(device.serial) }
    public var homePath: String { "/sdcard" }
    public var capabilities: SourceCapabilities { SourceCapabilities(permissions: true, search: true) }

    private func q(_ value: String) -> String { ShellText.quote(value) }

    // MARK: 瀏覽

    /// 列出目錄。`cd` 失敗（不存在／無權限）時丟 `cannotOpenDirectory`，
    /// 而不是像原版一樣默默回傳空清單。
    public func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
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
    public func search(in directory: String, query: String, maxDepth: Int = 4) async throws -> [FileItem] {
        let command = "find \(q(directory)) -maxdepth \(maxDepth) -iname \(q("*\(query)*")) "
            + "-exec stat -L -c \(q(StatParser.format)) {} + 2>/dev/null"
        return StatParser.parse(try await device.shell(command, timeout: .seconds(60)), parent: nil)
    }

    public func isDirectory(_ path: String) async throws -> Bool {
        try await device.shell("cd \(q(path)) 2>/dev/null && echo OK").contains("OK")
    }

    public func exists(_ path: String) async throws -> Bool {
        try await device.shell("test -e \(q(path)) && echo OK").contains("OK")
    }

    // MARK: 修改

    public func makeDirectory(at path: String) async throws {
        _ = try await device.shell("mkdir -p -- \(q(path))", check: true)
    }

    public func move(_ path: String, to target: String) async throws {
        _ = try await device.shell("mv -- \(q(path)) \(q(target))", check: true, timeout: nil)
    }

    public func copy(_ path: String, to target: String) async throws {
        _ = try await device.shell("cp -r -- \(q(path)) \(q(target))", check: true, timeout: nil)
    }

    public func delete(_ path: String) async throws {
        guard RemotePath.normalize(path) != "/" else { throw AdbError.invalidArgument("Refusing to delete /") }
        _ = try await device.shell("rm -rf -- \(q(path))", check: true, timeout: .seconds(120))
    }

    /// `mode` 只接受 3～4 位八進位（`755`、`0644`），杜絕被拼進 shell 的任意字串
    public func changeMode(_ path: String, mode: String) async throws {
        guard mode.range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) != nil else {
            throw AdbError.invalidArgument(String(localized: "Invalid permission mode: \(mode)"))
        }
        _ = try await device.shell("chmod \(mode) -- \(q(path))", check: true)
    }

    /// 安裝裝置上的 APK（`pm install`）；本機 APK 用 `DeviceConnection.install(localApk:)`
    public func installApk(_ path: String) async throws -> String {
        let output = try await device.shell("pm install -r \(q(path))", check: true, timeout: nil)
        return output.joined(separator: "\n")
    }

    // MARK: 傳輸

    /// Mac → 裝置。`adb push` 對不存在的目的路徑會直接建立（檔案或整個資料夾）。
    ///
    /// 進度：原版解析 `adb push -p` 的 `[ 42%]`，但新版 adb 已把 `-p` 當成相容旗標
    /// 靜默忽略、非 TTY 下也不印進度列，所以改為每 0.5 秒 `stat` 一次遠端檔案大小。
    /// 資料夾的進度為不確定（不回報）。
    public func upload(_ localURL: URL, to remotePath: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            throw AdbError.invalidArgument(String(localized: "Local file does not exist: \(localURL.path)"))
        }
        let total = isDirectory.boolValue ? 0
            : ((try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0)
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

    /// 裝置 → Mac。`adb pull` 沒有進度輸出，改為輪詢本機檔案大小
    /// （與原版 `pullWithProgress` 相同手法）；`expectedSize` 未知（資料夾）時不回報進度。
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
}
