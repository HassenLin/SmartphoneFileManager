import Foundation

/// 把終端機輸入的 adb 指令切成參數陣列，不經過本機 shell（原版 `CommandLineTokenizer` 逐行移植）。
///
/// 規則：單引號內原樣保留；雙引號與裸字中 `\\`、`\"`、`\<空白>` 為跳脫；
/// 引號未閉合丟 `AdbError.invalidArgument`。
public enum CommandLineTokenizer {
    public static func tokenize(_ command: String) throws -> [String] {
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return [] }

        var result: [String] = []
        var current = ""
        var quote: Character?
        var tokenStarted = false
        let chars = Array(command)
        var index = 0

        while index < chars.count {
            let char = chars[index]
            if char == "\\", quote != "'" {
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                if let next, next == "\\" || next == "\"" || (quote == nil && next.isWhitespace) {
                    current.append(next)
                    index += 1
                } else {
                    current.append(char)
                }
                tokenStarted = true
            } else if let q = quote, char == q {
                quote = nil
                tokenStarted = true
            } else if quote != nil {
                current.append(char)
                tokenStarted = true
            } else if char == "'" || char == "\"" {
                quote = char
                tokenStarted = true
            } else if char.isWhitespace {
                if tokenStarted {
                    result.append(current)
                    current = ""
                    tokenStarted = false
                }
            } else {
                current.append(char)
                tokenStarted = true
            }
            index += 1
        }

        if quote != nil { throw AdbError.invalidArgument("Unclosed quote in command") }
        if tokenStarted { result.append(current) }
        return result
    }
}
