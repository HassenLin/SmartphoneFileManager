import Foundation

/// 組 `lftp -c` 腳本：連線設定（`set …`）＋`open`＋操作指令。純函式、可單元測試。
///
/// lftp 實測行為（4.9.3）：
/// - 預設 `net:max-retries 1000`、`net:timeout 5m`：連不上時會重試很久才失敗，所以一律依帳號選項覆寫。
/// - `cmd:fail-exit yes`：腳本中任一指令失敗即結束（結束碼 1），不會繼續執行後面的指令。
/// - 訊息會依語系翻譯 → 執行時固定 `LC_ALL=C`，錯誤分類（`LftpError`）才比對得到。
/// - 密碼以 `open --env-password` 從環境變數 `LFTP_PASSWORD` 讀取，不會出現在行程參數（`ps` 看得到）與 log。
/// - 引號：lftp 自己解析指令列，雙引號內 `\"`、`\\` 為跳脫。
/// - `cls` 會展開萬用字元（`*?[]`），檔名含這些字元時要先以 `\` 跳脫；`get`／`put`／`rm`／`mv` 不展開。
/// - FTP 的 `cls -l --time-style=+%s`：MLSD 時為精確位元組數＋epoch（UTC），見 `LftpListingParser`。
struct LftpCommand: Sendable, Equatable {
    let account: NetworkAccount
    let options: ConnectionOptions.Resolved

    /// 雙引號字串（不展開萬用字元的指令用）
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `cls` 用：先跳脫萬用字元再加引號
    static func quoteGlob(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "*?[]\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return quote(escaped)
    }

    /// `open` 用的 URL（不含帳密）。FTPS implicit 用 `ftps://`；explicit 仍是 `ftp://` 加 `ftp:ssl-force`
    var url: String {
        let scheme: String
        switch account.protocol {
        case .sftp: scheme = "sftp"
        default: scheme = account.ftpSecurity == .implicit ? "ftps" : "ftp"
        }
        let host = account.host.trimmingCharacters(in: .whitespaces)
        // IPv6 位址要加中括號
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(hostPart):\(account.effectivePort)"
    }

    /// 連線設定（每行一條 `set`）
    var settings: [String] {
        var lines = [
            "set cmd:fail-exit yes",
            "set cmd:interactive no",
            "set net:timeout \(max(5, options.timeoutSeconds))",
            "set net:max-retries \(max(1, options.retries + 1))",
            "set net:reconnect-interval-base \(max(1, options.retryDelaySeconds))",
            "set net:reconnect-interval-multiplier 1",
            "set net:idle \(max(10, options.idleSeconds))",
            "set net:connection-limit \(max(1, options.maxConnections))",
            // 衝突由工作佇列決定（衝突對話框）；送到 lftp 時目的一律可覆寫
            "set xfer:clobber yes",
        ]
        switch account.protocol {
        case .sftp:
            // 主機金鑰：首次連線自動記住（TOFU），之後變了就拒絕；記在 app 自己的 known_hosts，
            // 不動使用者的 ~/.ssh/known_hosts（重設時也只改自己的檔，見 `SFTPHostKeys`）
            var ssh = "ssh -a -x -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30"
                // ssh 把 UserKnownHostsFile 的值以空白切成多個檔案，路徑（Application Support）要再包一層雙引號
                + " -o " + Self.shellQuote("UserKnownHostsFile=\"\(SFTPHostKeys.file.path)\"")
            if account.sftpAuth == .key {
                ssh += " -o IdentitiesOnly=yes -o PasswordAuthentication=no -i " + Self.shellQuote(account.sftpKeyPath)
            }
            lines.append("set sftp:connect-program " + Self.quote(ssh))
            if !options.ftpCharset.isEmpty { lines.append("set sftp:charset " + Self.quote(options.ftpCharset)) }
        default:
            lines.append("set ftp:passive-mode \(account.ftpMode == .passive ? "on" : "off")")
            switch account.ftpSecurity {
            case .none:
                lines.append("set ftp:ssl-allow no")
            case .explicit:
                lines += ["set ftp:ssl-force yes", "set ftp:ssl-protect-data yes", "set ftp:ssl-protect-list yes"]
            case .implicit:
                lines += ["set ftp:ssl-protect-data yes", "set ftp:ssl-protect-list yes"]
            }
            if account.ftpSecurity != .none {
                lines.append("set ssl:verify-certificate \(options.verifyCertificate ? "yes" : "no")")
            }
            if !options.ftpCharset.isEmpty { lines.append("set ftp:charset " + Self.quote(options.ftpCharset)) }
            if !options.serverTimeZone.isEmpty { lines.append("set ftp:timezone " + Self.quote(options.serverTimeZone)) }
            if account.ftpMode == .active {
                if !options.activeAddress.isEmpty { lines.append("set ftp:port-ipv4 " + Self.quote(options.activeAddress)) }
                if !options.activePortRange.isEmpty { lines.append("set ftp:port-range " + Self.quote(options.activePortRange)) }
            }
        }
        lines += Self.extraSettings(options.extraLftpCommands)
        return lines
    }

    /// 使用者自訂的額外指令：只接受 `set` 開頭的行（避免自由文字變成任意 lftp 指令，例如 `!shell`）
    static func extraSettings(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("set ") && !$0.contains(";") }
    }

    /// 額外指令中不合規則（會被忽略）的行，選項視窗顯示警告用
    static func rejectedExtraLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.hasPrefix("set ") && !$0.contains(";")) }
    }

    /// `open` 指令：使用者名稱以 `-u` 傳，密碼走環境變數。
    /// SFTP 金鑰登入時給空密碼（`-u "user,"`），ssh 若仍要密碼會立刻失敗，而不是卡在等待輸入。
    var open: String {
        if account.protocol == .sftp, account.sftpAuth == .key {
            return "open -u " + Self.quote(account.username + ",") + " " + Self.quote(url)
        }
        return "open --env-password -u " + Self.quote(account.username) + " " + Self.quote(url)
    }

    /// 完整腳本：設定＋open＋指令，以換行分隔（lftp -c 接受多行）
    func script(_ commands: [String]) -> String {
        (settings + [open] + commands).joined(separator: "\n")
    }

    /// sh 單引號跳脫（只用在 `sftp:connect-program` 的私鑰路徑：那一串由 lftp 交給 sh 執行）
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// SFTP 主機金鑰（app 專用的 known_hosts：`Application Support/SmartphoneFileManager/known_hosts`）
public enum SFTPHostKeys {
    public static let file = QueueStore.standard.directory.appendingPathComponent("known_hosts")

    /// known_hosts 的主機寫法：非 22 埠為 `[host]:port`
    static func entryName(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// 已記住的金鑰指紋（SHA256:…）；沒有時為 nil
    public static func fingerprint(host: String, port: Int) async -> String? {
        guard FileManager.default.fileExists(atPath: file.path),
              let output = try? await ProcessRunner.run("/usr/bin/ssh-keygen",
                                                        ["-l", "-F", entryName(host: host, port: port), "-f", file.path],
                                                        timeout: .seconds(10)),
              output.exitCode == 0 else { return nil }
        // 輸出：`# Host [h]:2222 found: line 1` 之後 `[h]:2222 ED25519 SHA256:xxxx`
        return output.lines.first { !$0.hasPrefix("#") }?.split(separator: " ").first { $0.hasPrefix("SHA256:") }.map(String.init)
    }

    /// 忘記主機金鑰（伺服器重灌、換金鑰時；下次連線重新記住）
    public static func reset(host: String, port: Int) async throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        _ = try await ProcessRunner.run("/usr/bin/ssh-keygen", ["-R", entryName(host: host, port: port), "-f", file.path],
                                        timeout: .seconds(10))
        try? FileManager.default.removeItem(atPath: file.path + ".old")
    }
}
