import Foundation

/// 裝置端（Android `sh`）字串處理。
///
/// `adb shell a b c` 會把參數以空白串起來交給裝置上的 `sh -c` 執行，所以
/// **所有路徑都必須自己單引號跳脫**——這是整個 ADB 層最容易出錯的地方，集中在此。
public enum ShellText {
    /// POSIX 單引號跳脫：`it's` → `'it'\''s'`
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 給互動式 shell 輸入用：不含特殊字元時保持原樣（tab 補完的觀感）
    public static func quoteForInput(_ path: String) -> String {
        if path.isEmpty { return path }
        if !path.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" }) { return path }
        return quote(path)
    }
}

/// 裝置端絕對路徑運算（一律以 `/` 開頭，不依賴 Foundation 的本機路徑語意）。
public enum RemotePath {
    public static func join(_ parent: String, _ name: String) -> String {
        if name.hasPrefix("/") { return normalize(name) }
        let base = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
        return normalize((base.isEmpty ? "" : base) + "/" + name)
    }

    public static func parent(of path: String) -> String {
        let parts = components(path)
        return parts.count <= 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")
    }

    public static func name(of path: String) -> String {
        components(path).last ?? "/"
    }

    public static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// 解析 `.`、`..` 與重複的 `/`；永遠回傳以 `/` 開頭的路徑
    public static func normalize(_ path: String) -> String {
        var stack: [String] = []
        for part in components(path) {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(part)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    /// 相對於目前目錄解析（終端機 tab 補完、符號連結目標用）
    public static func resolve(_ path: String, from current: String) -> String {
        path.hasPrefix("/") ? normalize(path) : join(current, path)
    }
}
