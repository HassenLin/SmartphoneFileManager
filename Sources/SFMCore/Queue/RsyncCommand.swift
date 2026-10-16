import Foundation

/// 兩邊都是這台 Mac 的同步：直接執行 rsync。
///
/// 用 PATH／Homebrew 找到的 rsync（有裝 Homebrew rsync 3.x 時用它），否則系統內建的 `/usr/bin/rsync`
/// （macOS 15 起為 openrsync，相容 rsync 2.6.9 協定）。兩者大部分選項相同，唯一差在延伸屬性：
/// openrsync 為 `--extended-attributes`，rsync 3.x 為 `--xattrs`。
///
/// 一律 `-a`（遞迴、保留時間／權限／連結）＋ `--itemize-changes`（逐項輸出，用來統計結果）。
/// 來源路徑結尾加 `/`：同步資料夾「內容」到目的資料夾（目的不存在時 rsync 會建立）。
public struct RsyncCommand: Sendable {
    public let options: SyncOptions
    /// `--update`：目的端較新的檔案不覆蓋（雙向同步的兩趟都用）。雙向時一律不加 `--delete`
    public let update: Bool

    public init(options: SyncOptions, update: Bool = false) {
        self.options = options
        self.update = update
    }

    /// 結果摘要（由 `--itemize-changes` 統計）
    public struct Summary: Sendable, Equatable {
        public var transferred = 0
        public var deleted = 0

        public var text: String {
            String(localized: "rsync: \(transferred) file(s) updated, \(deleted) item(s) deleted")
        }
    }

    public static func locate() -> String? {
        AdbLocator.findExecutable("rsync") ?? (FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync") ? "/usr/bin/rsync" : nil)
    }

    /// 組參數（`openrsync`：是否為系統內建版本，決定延伸屬性的寫法）
    public func arguments(from source: String, to target: String, openrsync: Bool) throws -> [String] {
        var args = ["-a", "--itemize-changes"]
        if options.checksum { args.append("--checksum") }
        if options.extendedAttributes { args.append(openrsync ? "--extended-attributes" : "--xattrs") }
        if update { args.append("--update") }
        if options.deleteExtraneous && !update { args.append("--delete") }
        if options.sizeOnly { args.append("--size-only") }
        if options.ignoreExisting { args.append("--ignore-existing") }
        if !options.includeHidden { args.append("--exclude=.*") }
        args += options.excludePatterns.filter { !$0.isEmpty }.map { "--exclude=\($0)" }
        let extra = options.extraArguments.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { args += try CommandLineTokenizer.tokenize(extra) }
        let from = RemotePath.normalize(source)
        args += [from == "/" ? "/" : from + "/", RemotePath.normalize(target)]
        return args
    }

    /// `--itemize-changes` 的行：`>f+++++++++ a.txt`（傳檔）、`cd+++++++++ dir/`（建資料夾）、`*deleting   old.txt`
    static func summarize(_ lines: [String]) -> Summary {
        var summary = Summary()
        for line in lines {
            if line.hasPrefix("*deleting") { summary.deleted += 1 }
            else if line.hasPrefix(">f") || line.hasPrefix("<f") { summary.transferred += 1 }
        }
        return summary
    }

    public func run(from source: String, to target: String) async throws -> Summary {
        guard let rsync = Self.locate() else { throw AdbError.executableNotFound("rsync") }
        let version = (try? await ProcessRunner.run(rsync, ["--version"], timeout: .seconds(10)))?.text ?? ""
        let args = try arguments(from: source, to: target, openrsync: version.contains("openrsync"))
        var lines: [String] = []
        for try await line in ProcessRunner.lines(rsync, args) { lines.append(line) }
        return Self.summarize(lines)
    }
}
