import AppKit

/// 輕量語法上色（原版 `CodeSyntaxHighlighter` 的規則逐條移植）。
///
/// 做法：依語言套一串正規表示式，先套用的規則「佔用」該範圍，後面的規則不覆蓋
/// （所以註解內的字串、關鍵字不會被重複上色）。不是真正的語法分析，夠用即可。
enum SyntaxHighlighter {
    enum TokenType { case comment, string, number, keyword, property, tag }

    static let maxLength = 500_000

    static func language(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "kt", "kts": return "Kotlin"
        case "java": return "Java"
        case "js", "jsx", "ts", "tsx": return "JavaScript"
        case "json": return "JSON"
        case "xml", "html", "htm", "svg": return "Markup"
        case "css", "scss": return "CSS"
        case "py": return "Python"
        case "sh", "bash", "zsh", "rc": return "Shell"
        case "yaml", "yml": return "YAML"
        case "sql": return "SQL"
        case "md", "markdown": return "Markdown"
        case "properties", "prop", "ini", "conf", "cfg", "toml", "gradle", "env": return "Config"
        case "c", "h", "cpp", "hpp", "swift": return "C"
        default: return "Plain text"
        }
    }

    static func color(for type: TokenType) -> NSColor {
        switch type {
        case .comment: return .systemGray
        case .string: return .systemRed
        case .number: return .systemPurple
        case .keyword: return .systemPink
        case .property: return .systemTeal
        case .tag: return .systemBlue
        }
    }

    static func tokens(in text: String, fileName: String) -> [(NSRange, TokenType)] {
        let ns = text as NSString
        guard ns.length > 0, ns.length <= maxLength else { return [] }
        let language = language(for: fileName)
        guard language != "Plain text" else { return [] }

        var occupied = IndexSet()
        var result: [(NSRange, TokenType)] = []
        func add(_ pattern: String, _ type: TokenType, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range
                guard range.length > 0, !occupied.intersects(integersIn: range.location..<NSMaxRange(range)) else { continue }
                occupied.insert(integersIn: range.location..<NSMaxRange(range))
                result.append((range, type))
            }
        }

        switch language {
        case "Markup":
            add("<!--[\\s\\S]*?-->", .comment)
            add("</?[A-Za-z][^>]*?>", .tag)
            add("\"[^\"]*\"|'[^']*'", .string)
        case "Markdown":
            add("^\\s{0,3}#{1,6}\\s+.*$", .tag, options: .anchorsMatchLines)
            add("`{1,3}[^`]*`{1,3}", .string)
            add("^\\s*>.*$", .comment, options: .anchorsMatchLines)
            add("\\[[^\\]]+\\]\\([^)]+\\)", .property)
        default:
            if ["Kotlin", "Java", "JavaScript", "CSS", "SQL", "Config", "C"].contains(language) {
                add("/\\*[\\s\\S]*?\\*/|//.*$", .comment, options: .anchorsMatchLines)
            }
            if ["Python", "Shell", "YAML", "Config"].contains(language) {
                add("(?<!\\\\)#.*$", .comment, options: .anchorsMatchLines)
            }
            if language == "SQL" { add("--.*$", .comment, options: .anchorsMatchLines) }
            if ["JSON", "YAML", "Config"].contains(language) {
                add("([A-Za-z_][\\w.-]*|\"(?:\\\\.|[^\"\\\\])*\")(?=\\s*[:=])", .property, options: .anchorsMatchLines)
            }
            add("\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'", .string)
            add("(?<![\\w.])(?:0[xX][0-9a-fA-F]+|\\d+(?:\\.\\d+)?)(?![\\w.])", .number)
            let words = keywords(for: language)
            if !words.isEmpty {
                add("\\b(?:" + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b",
                    .keyword, options: .caseInsensitive)
            }
        }
        return result
    }

    static func keywords(for language: String) -> [String] {
        switch language {
        case "Kotlin": return ["as", "break", "class", "continue", "data", "do", "else", "false", "for", "fun", "if", "in", "interface", "is", "null", "object", "package", "private", "protected", "public", "return", "sealed", "suspend", "this", "throw", "true", "try", "typealias", "val", "var", "when", "while"]
        case "Java": return ["abstract", "boolean", "break", "case", "catch", "class", "continue", "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "if", "implements", "import", "instanceof", "interface", "new", "null", "package", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "throws", "true", "try", "void", "while"]
        case "JavaScript": return ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "while", "yield"]
        case "Python": return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case "SQL": return ["alter", "and", "as", "asc", "begin", "by", "case", "create", "delete", "desc", "distinct", "drop", "else", "end", "from", "group", "having", "in", "index", "insert", "into", "is", "join", "limit", "not", "null", "on", "or", "order", "select", "set", "table", "then", "union", "update", "values", "when", "where"]
        case "JSON": return ["true", "false", "null"]
        case "Shell": return ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "return", "then", "while"]
        case "C": return ["break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "if", "int", "let", "long", "return", "short", "sizeof", "static", "struct", "switch", "typedef", "unsigned", "var", "void", "while", "func", "import"]
        default: return []
        }
    }

    /// 重設整份文件的前景色並套用 token 顏色（只改 foregroundColor，不動字型，undo 不受影響）
    static func apply(to storage: NSTextStorage, fileName: String) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
        for (range, type) in tokens(in: storage.string, fileName: fileName) {
            storage.addAttribute(.foregroundColor, value: color(for: type), range: range)
        }
        storage.endEditing()
    }
}
