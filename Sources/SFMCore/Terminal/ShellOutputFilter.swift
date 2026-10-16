import Foundation

/// 互動式 `adb shell` 輸出過濾（原版 `ShellOutputFilter` 移植）。
///
/// 背景：沒有 TTY 的 `adb shell` 不會告訴我們目前目錄，所以每送出一條指令後
/// 追加一條 `printf '__AFM_PWD__=%s\n' "$PWD"`，由這裡攔下標記行更新提示字元，
/// 並濾掉我們自己注入的指令回顯與殘留的提示字元。
public struct ShellOutputFilter: Sendable {
    public static let pwdMarker = "__AFM_PWD__="
    public static let initCommand = "stty -echo 2>/dev/null; export PS1=''"
    public static let pwdCommand = "printf '\(pwdMarker)%s\\n' \"$PWD\""

    public enum Result: Equatable, Sendable {
        case output(String)
        case directory(String)
        case suppressed
    }

    nonisolated(unsafe) private static let promptPattern =
        /^(?:\[?[a-zA-Z0-9_.\/~-]+@[a-zA-Z0-9_.\/~-]+.*[\]#$]|(?:\/\S*)?\s*[$#])\s*$/

    public init() {}

    public func filter(_ rawLine: String) -> Result {
        let line = rawLine.replacingOccurrences(of: "\r", with: "").replacingOccurrences(
            of: #"\s+$"#, with: "", options: .regularExpression)
        if let range = line.range(of: Self.pwdMarker) {
            let directory = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return .directory(directory.isEmpty ? "/" : directory)
        }
        let injected = ["__AFM_PWD__", "stty -echo", "export PS1=", "$PWD\"", "%s\\n"]
        if injected.contains(where: line.contains) { return .suppressed }
        if line.trimmingCharacters(in: .whitespaces).wholeMatch(of: Self.promptPattern) != nil { return .suppressed }
        return .output(line)
    }
}

/// Tab 補完用的純函式（可單元測試）
public enum ShellCompletion {
    public struct Token: Equatable, Sendable {
        public let startIndex: Int
        public let value: String
    }

    /// 找出游標（字串尾端）所在的待補完 token；引號內的空白不算分隔
    public static func token(in command: String) -> Token {
        var quote: Character?
        var start = 0
        for (index, char) in command.enumerated() {
            if let q = quote, char == q {
                quote = nil
            } else if quote == nil, char == "'" || char == "\"" {
                quote = char
                start = index
            } else if quote == nil, char.isWhitespace {
                start = index + 1
            }
        }
        var value = String(command.dropFirst(start))
        if value.hasPrefix("\"") || value.hasPrefix("'") { value.removeFirst() }
        return Token(startIndex: start, value: value)
    }

    public static func longestCommonPrefix(_ values: [String]) -> String {
        guard var prefix = values.first else { return "" }
        for value in values.dropFirst() {
            while !value.hasPrefix(prefix), !prefix.isEmpty { prefix.removeLast() }
        }
        return prefix
    }
}
