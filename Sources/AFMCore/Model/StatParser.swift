import Foundation

/// 解析裝置端 `stat -L -c <format>` 輸出。
///
/// 與原版的差異：原版格式 `%F|%A|%h|%U|%G|%s|%Y|%n|%N` 以 `|` 切 9 欄，檔名含 `|`
/// 就會錯位；這裡把檔名 `%n` 放在**最後一欄**並限制切割次數，檔名含 `|` 也正確。
/// `-L` 會跟隨符號連結，連到目錄的連結因此可以直接進入（原版行為）。
public enum StatParser {
    /// 檔案型別｜權限｜大小｜修改時間（epoch 秒）｜名稱
    public static let format = "%F|%A|%s|%Y|%n"

    /// - Parameter parent: 列目錄時傳入目錄路徑（`%n` 是相對名稱）；
    ///   搜尋時傳 nil（`find` 給的 `%n` 已是絕對路徑）。
    public static func parse(_ lines: [String], parent: String?) -> [RemoteFile] {
        lines.compactMap { parseLine($0, parent: parent) }
    }

    static func parseLine(_ line: String, parent: String?) -> RemoteFile? {
        let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, !fields[4].isEmpty else { return nil }
        let type = fields[0].lowercased()
        // 只接受 stat 真的會印出的型別字樣，擋掉夾雜在輸出中的錯誤訊息
        guard type.contains("file") || type.contains("directory") || type.contains("link")
                || type.contains("fifo") || type.contains("socket") || type.contains("special") else { return nil }

        let rawName = fields[4]
        let path = parent.map { RemotePath.join($0, rawName) } ?? RemotePath.normalize(rawName)
        let seconds = TimeInterval(fields[3])
        return RemoteFile(
            path: path,
            name: RemotePath.name(of: path),
            isDirectory: type.contains("directory"),
            size: Int64(fields[2]) ?? 0,
            modified: seconds.map { Date(timeIntervalSince1970: $0) },
            permissions: fields[1]
        )
    }
}
