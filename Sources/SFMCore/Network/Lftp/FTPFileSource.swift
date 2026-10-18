import Foundation

/// FTP／FTPS（explicit、implicit；主動、被動）與 SFTP 的檔案來源，透過 lftp。
///
/// 為什麼用 lftp 而不自寫協定：一個工具涵蓋 FTP 主動／被動、FTPS 兩種模式、SFTP（密碼或金鑰），
/// 且內建續傳（`get -c`／`put -c`）、檔名編碼轉換、重試；自寫 FTP 的資料通道、TLS session reuse
/// （許多 FTPS 伺服器要求資料通道沿用控制通道的 session）成本很高。
///
/// 與 afcclient 相同，**每個操作一個 lftp 行程**（`lftp -c 腳本`）：每次都要重新登入（約 0.1～1 秒），
/// 換來無狀態、可取消（終止行程即可）、不會有卡住的長連線。指令細節見 `LftpCommand`。
public struct FTPFileSource: FileSource {
    public let account: NetworkAccount
    let command: LftpCommand
    let executable: String
    let password: String

    init(account: NetworkAccount, password: String, options: ConnectionOptions.Resolved, executable: String) {
        self.account = account
        self.command = LftpCommand(account: account, options: options)
        self.executable = executable
        self.password = password
    }

    /// 找 lftp（PATH + Homebrew）；未安裝時為 nil
    public static func locateTool() -> String? { AdbLocator.findExecutable("lftp") }

    public var id: SourceID { account.sourceID }
    public var homePath: String { account.normalizedRootPath }
    /// FTP／SFTP 沒有伺服器端複製，同來源複製經 Mac 中繼
    public var capabilities: SourceCapabilities { SourceCapabilities(nativeCopy: false, resumable: true) }

    // MARK: 執行

    /// 執行一組指令；結束碼非 0 時依輸出分類成 `NetworkError`
    @discardableResult
    func run(_ commands: [String], timeout: Duration? = nil) async throws -> [String] {
        let options = command.options
        // 預設逾時：每次嘗試的逾時 ×（重試次數＋1）再加緩衝
        let limit = timeout ?? .seconds(max(5, options.timeoutSeconds) * (max(0, options.retries) + 1) + 15)
        return try await execute(commands, timeout: limit)
    }

    /// 傳輸類：不設總時限（大檔可能很久），斷線由 lftp 的 `net:timeout` 偵測
    private func runTransfer(_ commands: [String]) async throws {
        try await execute(commands, timeout: nil)
    }

    @discardableResult
    private func execute(_ commands: [String], timeout: Duration?) async throws -> [String] {
        var environment = ["LC_ALL": "C", "LANG": "C", "LFTP_PASSWORD": password]
        if account.protocol == .ftp, account.ftpSecurity != .none, let config = Self.tls12Config {
            environment["OPENSSL_CONF"] = config.path
        }
        let output = try await ProcessRunner.run(executable, ["-c", command.script(commands)], timeout: timeout,
                                                 environment: environment)
        guard output.exitCode == 0 else { throw LftpError.classify(output.text, exitCode: output.exitCode) }
        return output.lines
    }

    /// FTPS 一律限制在 TLS 1.2：**lftp 4.9.3＋OpenSSL 3 在 TLS 1.3 資料通道上傳會截斷檔尾**。
    ///
    /// 實測（pyftpdlib TLS 1.3 伺服器）：1.5 MiB 上傳只存到 1.1～1.4 MiB，且 lftp 回報成功；
    /// 同一伺服器以 Python ftplib（OpenSSL TLS 1.3）上傳完整、TLS 1.2 伺服器 6/6 完整 → 問題在 lftp 端。
    /// `ssl:priority` 只對 GnuTLS 版有效（Homebrew 的 lftp 連結 OpenSSL），所以改以 `OPENSSL_CONF`
    /// 指向只含 `MaxProtocol = TLSv1.2` 的設定檔，只影響這個 lftp 行程。上傳後另有大小驗證（`putFile`）。
    static let tls12Config: URL? = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sfm-lftp-openssl-tls12.cnf")
        let text = """
            # Smartphone File Manager：lftp FTPS 限制 TLS 1.2（避開 lftp 的 TLS 1.3 上傳截斷）
            openssl_conf = sfm_conf
            [sfm_conf]
            ssl_conf = sfm_ssl
            [sfm_ssl]
            system_default = sfm_tls
            [sfm_tls]
            MaxProtocol = TLSv1.2

            """
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }()

    private static func q(_ path: String) -> String { LftpCommand.quote(path) }

    // MARK: 瀏覽

    public func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
        let directory = RemotePath.normalize(directory)
        let lines = try await run(["cls -l -a --time-style=+%s " + LftpCommand.quoteGlob(directory == "/" ? "/" : directory + "/")])
        return LftpListingParser.parse(lines)
            .filter { RemotePath.parent(of: $0.path) == directory && (includeHidden || !$0.isHidden) }
    }

    public func stat(_ path: String) async throws -> FileStat? {
        let path = RemotePath.normalize(path)
        guard path != "/" else { return FileStat(size: 0, modified: nil, isDirectory: true) }
        do {
            let lines = try await run(["cls -d -l --time-style=+%s " + LftpCommand.quoteGlob(path)])
            return LftpListingParser.parse(lines).first.map {
                FileStat(size: $0.size, modified: $0.modified, isDirectory: $0.isDirectory)
            }
        } catch NetworkError.notFound {
            return nil
        }
    }

    public func isDirectory(_ path: String) async throws -> Bool { try await stat(path)?.isDirectory ?? false }
    public func exists(_ path: String) async throws -> Bool { try await stat(path) != nil }

    // MARK: 檔案操作

    public func makeDirectory(at path: String) async throws {
        try await run(["mkdir " + Self.q(path)])
    }

    /// FTP RNFR/RNTO、SFTP rename：伺服器端完成，瞬間
    public func move(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await run(["mv " + Self.q(path) + " " + Self.q(target)])
        onProgress(1)
    }

    public func copy(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        // capabilities.nativeCopy == false：工作佇列不會呼叫；保險起見明確拒絕而非默默做錯
        throw NetworkError.server(String(localized: "FTP and SFTP servers cannot copy files on the server."))
    }

    public func delete(_ path: String) async throws {
        guard RemotePath.normalize(path) != "/" else { throw AdbError.invalidArgument("Refusing to delete /") }
        let isDirectory = try await self.isDirectory(path)
        try await run([(isDirectory ? "rm -r " : "rm ") + Self.q(path)], timeout: .seconds(600))
    }

    // MARK: 傳輸

    public func download(_ path: String, to localURL: URL, expectedSize: Int64?,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if try await isDirectory(path) {
            // mirror：把遠端資料夾的內容鏡像到本機資料夾（不存在會建立）
            return try await runTransfer(["mirror --no-perms " + Self.q(path) + " " + Self.q(localURL.path)])
        }
        try? FileManager.default.removeItem(at: localURL)
        try await getFile(path, to: localURL, resume: false, total: expectedSize ?? 0, onProgress: onProgress)
    }

    public func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if NetworkTransfer.localIsDirectory(localURL) {
            return try await runTransfer(["mirror -R --no-perms " + Self.q(localURL.path) + " " + Self.q(path)])
        }
        try await putFile(localURL, to: path, resume: false, onProgress: onProgress)
    }

    /// 進度：lftp 在非 TTY 不輸出進度，輪詢本機檔案大小（便宜，0.3 秒一次）
    private func getFile(_ path: String, to localURL: URL, resume: Bool, total: Int64,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let localPath = localURL.path
        try await NetworkTransfer.withPolling(total: total, interval: .milliseconds(300), onProgress: onProgress, size: {
            NetworkTransfer.localSize(URL(fileURLWithPath: localPath))
        }) { [self] in
            try await runTransfer([(resume ? "get -c " : "get ") + Self.q(path) + " -o " + Self.q(localPath)])
        }
    }

    /// 進度：輪詢遠端大小——每次輪詢都是一次新登入，所以 2 秒一次
    private func putFile(_ localURL: URL, to path: String, resume: Bool,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let total = NetworkTransfer.localSize(localURL)
        try await NetworkTransfer.withPolling(total: total, interval: .seconds(2), onProgress: onProgress, size: { [self] in
            (try? await stat(path)?.size) ?? 0
        }) { [self] in
            try await runTransfer([(resume ? "put -c " : "put ") + Self.q(localURL.path) + " -o " + Self.q(path)])
        }
        // lftp 偶有回報成功但檔尾不完整的情況（見 `tls12Config`）：大小不符一律視為失敗，佇列可續傳補齊
        let remote = try await stat(path)?.size
        guard remote == total else {
            throw NetworkError.server(String(localized: "Upload incomplete: \(remote ?? 0) of \(total) bytes reached the server"))
        }
    }

    // MARK: 續傳（lftp 內建：`get -c` 從本機檔大小、`put -c` 從遠端檔大小接續，FTP REST／SFTP offset）

    public func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if NetworkTransfer.localSize(localURL) > totalSize { try? FileManager.default.removeItem(at: localURL) }
        try await getFile(path, to: localURL, resume: true, total: totalSize, onProgress: onProgress)
    }

    public func resumeUpload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if let remote = try await stat(path)?.size, remote > NetworkTransfer.localSize(localURL) { try await discard(path) }
        try await putFile(localURL, to: path, resume: true, onProgress: onProgress)
    }
}
