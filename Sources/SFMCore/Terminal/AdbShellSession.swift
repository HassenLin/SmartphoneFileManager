import Foundation
import Observation

/// 終端機分頁的工作階段（原版 `AdbShellSession` 移植）。
///
/// 有限狀態機，兩個停留狀態：
/// - `.adb`：只接受 `adb ...` 指令，每條指令啟動一個 adb 子行程；
///   輸入 `adb shell`（不帶參數）→ 進入 `.shell`
/// - `.shell`：持續存在的 `adb -s <serial> shell` 子行程，輸入直接寫進其 stdin；
///   輸入 `exit` 或子行程結束 → 回到 `.adb`
/// 另有終止狀態 `closed`（`close()` 後不再接受任何輸入）。
///
/// 併發契約：所有狀態只在 MainActor 上修改；背景讀取執行緒以 `Task { @MainActor }` 回送輸出。
@MainActor
@Observable
public final class AdbShellSession: Identifiable {
    public enum Mode: Sendable { case adb, shell }

    public let id = UUID()
    public let serial: String
    public private(set) var output: String
    public private(set) var mode: Mode = .adb
    public private(set) var currentDirectory = "/"
    public private(set) var isClosed = false

    @ObservationIgnored private let adbPath: String
    @ObservationIgnored private var shellHandle: ProcessHandle?
    @ObservationIgnored private var shellInput: FileHandle?
    @ObservationIgnored private var commandTasks: [UUID: Task<Void, Never>] = [:]

    /// 輸出上限，避免長時間 `logcat` 把記憶體吃光（原版 500k 字元）
    static let maxOutputCharacters = 300_000

    public init(adbPath: String, serial: String) {
        self.adbPath = adbPath
        self.serial = serial
        self.output = String(localized: "ADB terminal for \(serial)\nType adb shell to enter the device shell.\n")
    }

    public var prompt: String {
        switch mode {
        case .adb: return "$ "
        case .shell: return "\(currentDirectory) $ "
        }
    }

    public func send(_ rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, !isClosed else { return }
        append("\(prompt)\(command)\n")
        if command.caseInsensitiveCompare("clear") == .orderedSame {
            clear()
            return
        }
        switch mode {
        case .shell: writeToShell(command)
        case .adb: handleAdbModeCommand(command)
        }
    }

    public func clear() { output = "" }

    public func showCandidates(_ candidates: [String]) {
        if !candidates.isEmpty { append(candidates.joined(separator: "  ") + "\n") }
    }

    /// 中斷目前執行中的 adb 指令（Ctrl-C 的近似；shell 模式下無 TTY，無法送 SIGINT 給裝置端行程）
    public func interrupt() {
        commandTasks.values.forEach { $0.cancel() }
        if mode == .shell { append(String(localized: "^C (not supported in shell mode without a TTY; type exit to leave)\n")) }
    }

    // MARK: ADB 模式

    private func handleAdbModeCommand(_ command: String) {
        let tokens: [String]
        do {
            tokens = try CommandLineTokenizer.tokenize(command)
        } catch {
            append("\(error.localizedDescription)\n")
            return
        }
        guard tokens.first?.lowercased() == "adb" else {
            append(String(localized: "ADB mode only accepts adb commands. Type adb shell to enter the device shell.\n"))
            return
        }
        if tokens.count == 2, tokens[1] == "shell" {
            startShell()
        } else {
            runAdb(Array(tokens.dropFirst()))
        }
    }

    private func runAdb(_ arguments: [String]) {
        let id = UUID()
        let adbPath = self.adbPath
        commandTasks[id] = Task { [weak self] in
            do {
                for try await line in ProcessRunner.lines(adbPath, arguments) {
                    self?.append(line + "\n")
                }
            } catch is CancellationError {
                self?.append("^C\n")
            } catch let AdbError.commandFailed(code, _) {
                self?.append(String(localized: "\nadb exited with code \(Int(code)).\n"))
            } catch {
                self?.append(String(localized: "Failed to run adb: \(error.localizedDescription)\n"))
            }
            self?.commandTasks[id] = nil
        }
    }

    // MARK: Shell 模式

    private func startShell() {
        guard shellHandle == nil else { return }
        append(String(localized: "Entering device shell...\n"))
        let handle = ProcessRunner.makeHandle(adbPath, ["-s", serial, "shell"], environment: nil)
        let input = Pipe()
        handle.process.standardInput = input
        do {
            try handle.run()
        } catch {
            append(String(localized: "Unable to start shell: \(error.localizedDescription)\n"))
            return
        }
        shellHandle = handle
        shellInput = input.fileHandleForWriting
        mode = .shell
        writeLine(ShellOutputFilter.initCommand)
        writeLine(ShellOutputFilter.pwdCommand)

        // 背景執行緒逐行讀取，經過濾後回送 MainActor
        // self 是 MainActor 物件，不能直接送進背景閉包；以弱參考盒子轉交，回到主執行緒才解開
        let owner = WeakBox(self)
        DispatchQueue.global(qos: .userInitiated).async {
            let reader = handle.pipe.fileHandleForReading
            let filter = ShellOutputFilter()
            var pending = Data()
            func deliver(_ bytes: Data) {
                let result = filter.filter(String(decoding: bytes, as: UTF8.self))
                // DispatchQueue.main 保證 FIFO 順序（多個 Task 不保證）
                DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.apply(result) } }
            }
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let index = pending.firstIndex(of: 0x0A) {
                    deliver(pending.subdata(in: pending.startIndex..<index))
                    pending.removeSubrange(pending.startIndex...index)
                }
            }
            if !pending.isEmpty { deliver(pending) }
            let status = handle.waitForExit()
            DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.shellDidExit(status: status) } }
        }
    }

    private func apply(_ result: ShellOutputFilter.Result) {
        switch result {
        case let .output(line): append(line + "\n")
        case let .directory(directory): currentDirectory = directory
        case .suppressed: break
        }
    }

    private func shellDidExit(status: Int32) {
        shellHandle = nil
        try? shellInput?.close()
        shellInput = nil
        guard !isClosed else { return }
        if status != 0 { append(String(localized: "\nShell exited with code \(Int(status)).\n")) }
        mode = .adb
        currentDirectory = "/"
        append(String(localized: "Returned to ADB mode.\n"))
    }

    private func writeToShell(_ command: String) {
        guard shellInput != nil else {
            append(String(localized: "Shell is not ready.\n"))
            return
        }
        writeLine(command)
        if command.caseInsensitiveCompare("exit") != .orderedSame { writeLine(ShellOutputFilter.pwdCommand) }
    }

    private func writeLine(_ line: String) {
        do {
            try shellInput?.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            append(String(localized: "Failed to send command: \(error.localizedDescription)\n"))
        }
    }

    // MARK: Tab 補完

    /// 回傳補完後的指令；多個候選時同時回傳候選清單（只在 shell 模式有效）
    public func complete(_ command: String) async -> (command: String, candidates: [String]) {
        guard mode == .shell else { return (command, []) }
        let token = ShellCompletion.token(in: command)
        let prefix = token.value
        let directoryPart = prefix.lastIndex(of: "/").map { String(prefix[...$0]) } ?? ""
        let namePrefix = String(prefix.dropFirst(directoryPart.count))
        let directory = directoryPart.isEmpty ? currentDirectory : RemotePath.resolve(directoryPart, from: currentDirectory)

        let device = AdbClient(executable: adbPath).device(serial)
        let listing = (try? await device.shell("ls -1 -a -- \(ShellText.quote(directory))", timeout: .seconds(5))) ?? []
        let names = listing.filter { $0 != "." && $0 != ".." && $0.hasPrefix(namePrefix) }.sorted()
        guard !names.isEmpty else { return (command, []) }

        let replacement: String
        if names.count == 1 {
            let path = directoryPart + names[0]
            let target = RemotePath.resolve(path, from: currentDirectory)
            let isDir = ((try? await device.shell("test -d \(ShellText.quote(target)) && echo D", timeout: .seconds(5))) ?? []).contains("D")
            replacement = ShellText.quoteForInput(path) + (isDir ? "/" : " ")
        } else {
            replacement = ShellText.quoteForInput(directoryPart + ShellCompletion.longestCommonPrefix(names))
        }
        let completed = String(command.prefix(token.startIndex)) + replacement
        return (completed, names.count > 1 ? names.map { directoryPart + $0 } : [])
    }

    // MARK: 輸出與關閉

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        output += text
        // utf8.count 是 O(1)，比 count（逐字元）便宜得多
        if output.utf8.count > Self.maxOutputCharacters {
            output = String(output.suffix(Self.maxOutputCharacters))
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        try? shellInput?.close()
        shellHandle?.cancel()
        commandTasks.values.forEach { $0.cancel() }
        commandTasks.removeAll()
    }
}

/// 跨執行緒轉交弱參考用。只在主執行緒解開 `value`（見 `startShell`）。
final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
