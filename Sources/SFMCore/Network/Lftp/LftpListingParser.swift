import Foundation

/// 解析 `cls -l --time-style=+%s <絕對路徑>` 的輸出。
///
/// 實測格式（MLSD 伺服器、SFTP）：
///
///     ---------- 501      0         3145728 1792325773 /big.bin
///     d--------- 501      0              64 1792325754 /中文 資料夾/
///     lrwxrwxrwx 0        0               7 1792325754 /link -> a.txt     （LIST 伺服器的符號連結）
///
/// 欄位：權限、擁有者、群組、大小、epoch、完整路徑（資料夾帶結尾 `/`）。擁有者／群組可能缺漏或含數字，
/// 所以從右邊找「大小 epoch /路徑」：路徑一定以 `/` 開頭（我們傳的是絕對路徑），擁有者／群組不會含 `/`。
/// 舊式 LIST 伺服器的時間若不是 epoch（無法解析）則 `modified` 為 nil，不影響其他欄位。
enum LftpListingParser {
    // Regex 字面值建立後不可變，跨執行緒共用安全（型別未標 Sendable 只因可能含自訂閉包，這裡沒有）
    nonisolated(unsafe) private static let pattern = /^([-dlcbpsD][-rwxsStTlL+.@]*)\s+(?:.*?\s+)??(\d+)\s+(-?\d+|[A-Z][a-z]{2} +\d{1,2} +[\d:]+)\s(\/.*)$/

    static func parse(_ lines: [String]) -> [FileItem] {
        lines.compactMap(parseLine)
    }

    static func parseLine(_ line: String) -> FileItem? {
        guard let match = line.wholeMatch(of: pattern) else { return nil }
        let permissions = String(match.1)
        var path = String(match.4)
        let isLink = permissions.hasPrefix("l")
        if isLink, let arrow = path.range(of: " -> ") { path = String(path[..<arrow.lowerBound]) }
        let isDirectory = permissions.hasPrefix("d") || path.hasSuffix("/")
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let name = RemotePath.name(of: path)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let modified = Double(match.3).map { Date(timeIntervalSince1970: $0) }
        return FileItem(path: path, isDirectory: isDirectory, size: isDirectory ? 0 : (Int64(match.2) ?? 0),
                        modified: modified, permissions: permissions)
    }
}

/// lftp 的錯誤輸出 → `NetworkError`（執行時固定 `LC_ALL=C`，訊息為英文）。
enum LftpError {
    static func classify(_ output: String, exitCode: Int32) -> NetworkError {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        // 只取最後一行有意義的訊息（前面可能有 `cd ok` 之類的雜訊）
        let message = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
        if lower.contains("login failed") || lower.contains("login incorrect") || lower.contains(" 530 ")
            || lower.contains("permission denied (publickey") || lower.contains("authentication failed") {
            return .authenticationFailed(message)
        }
        if lower.contains("certificate verification") || lower.contains("certificate") && lower.contains("not trusted") {
            return .untrustedCertificate(fingerprint: fingerprint(in: text))
        }
        if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
            return .server(String(localized: "The SFTP server's host key has changed. Reset it in the account options if this is expected."))
        }
        if lower.contains("no such file") || lower.contains(" 550 ") && (lower.contains("not found") || lower.contains("no such"))
            || lower.contains("file not found") {
            return .notFound(message)
        }
        if lower.contains("file exists") || lower.contains("already exists") {
            return .alreadyExists(message)
        }
        if lower.contains("max-retries exceeded") || lower.contains("connection refused") || lower.contains("timed out")
            || lower.contains("timeout") || lower.contains("name or service not known") || lower.contains("not resolve")
            || lower.contains("no route to host") || lower.contains("network is unreachable") {
            return .unreachable(message)
        }
        return .server(message.isEmpty ? "lftp exit code \(exitCode)" : message)
    }

    /// `Certificate verification: self-signed certificate (60:96:A0:…)` 中的 SHA-1 指紋（只供顯示）
    static func fingerprint(in text: String) -> String? {
        guard let match = text.firstMatch(of: /\(([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){15,})\)/) else { return nil }
        return String(match.1)
    }
}
