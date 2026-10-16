import Foundation
import os

/// 子行程執行結果。stdout 與 stderr 合併（對應原 Kotlin 版 `redirectErrorStream(true)`）。
public struct ProcessOutput: Sendable {
    public let exitCode: Int32
    public let data: Data

    public init(exitCode: Int32, data: Data) {
        self.exitCode = exitCode
        self.data = data
    }

    public var text: String { String(decoding: data, as: UTF8.self) }

    /// 逐行切開；去掉 `\r`，最後一個空行不算（與 Java `readLines()` 相同）。
    public var lines: [String] { Self.splitLines(text) }

    static func splitLines(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

/// 子行程控制代碼。
///
/// `Process` 不是 Sendable，但取消（Task cancel）與逾時會從別的執行緒呼叫
/// `terminate()`，所以把它包進這個以 `NSLock` 保護狀態的類別。
/// 併發契約：`run()`／`cancel()`／`expire()` 可由任意執行緒呼叫；
/// `cancel` 若先於 `run` 發生，`run` 會直接丟 `CancellationError` 不啟動行程。
final class ProcessHandle: @unchecked Sendable {
    let process: Process
    let pipe: Pipe
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false
    private let exited = DispatchSemaphore(value: 0)

    init(process: Process, pipe: Pipe) {
        self.process = process
        self.pipe = pipe
        // 以 terminationHandler 得知結束，而不用 waitUntilExit()：
        // waitUntilExit 會輪詢「目前執行緒」的 run loop，等 Foundation 的結束通知；
        // 實測在測試宿主（主執行緒被佔住）中於 GCD 執行緒上永遠等不到而卡死。
        // terminationHandler 由 Foundation 在自己的背景佇列呼叫，不依賴任何 run loop。
        process.terminationHandler = { [exited] _ in exited.signal() }
    }

    /// 阻塞等待行程結束並回傳結束碼（只可在背景執行緒呼叫）
    func waitForExit() -> Int32 {
        exited.wait()
        exited.signal()   // 讓重複呼叫也能立即返回
        return process.terminationStatus
    }

    func run() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }

    func expire() {
        lock.lock(); timedOut = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
    var isTimedOut: Bool { lock.withLock { timedOut } }
}

/// 執行外部程式（adb、scrcpy…）的唯一入口。
///
/// 設計重點：
/// - **不經過 host shell**：參數以陣列傳給 `Process`，檔名含空白／中文不需跳脫
///   （原 Windows 版 CP936 問題在 macOS 上不存在）。
/// - **可取消**：呼叫端的 Task 被取消時，子行程會收到 SIGTERM，不會留下孤兒 adb。
/// - **阻塞讀取放在 GCD 背景執行緒**：絕不卡住 MainActor。
public enum ProcessRunner {
    static let log = Logger(subsystem: "idv.hassen.smartphonefilemanager.mac", category: "process")

    /// 執行並收集全部輸出。
    /// - Parameters:
    ///   - timeout: `nil` 表示不逾時（檔案傳輸用）；逾時丟 `AdbError.timedOut`。
    ///   - standardOutput: 指定時 stdout 直接寫進該檔案（例如 `screencap` 的 PNG），
    ///     回傳的 `data` 只剩 stderr。
    ///   - standardInput: 指定時以該檔案（目前讀取位置起）作為 stdin（`adb exec-in` 續傳上傳用）。
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: Duration? = .seconds(30),
        environment: [String: String]? = nil,
        standardOutput: FileHandle? = nil,
        standardInput: FileHandle? = nil
    ) async throws -> ProcessOutput {
        let handle = makeHandle(executable, arguments, environment: environment)
        if let standardOutput { handle.process.standardOutput = standardOutput }
        if let standardInput { handle.process.standardInput = standardInput }
        log.debug("exec: \(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)")

        let output: ProcessOutput = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                do {
                    try handle.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                        handle.expire()
                    }
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    // 讀到 EOF 才等結束，避免輸出量大時 pipe 塞滿造成死結
                    let data = handle.pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: ProcessOutput(exitCode: handle.waitForExit(), data: data))
                }
            }
        } onCancel: {
            handle.cancel()
        }

        if handle.isTimedOut { throw AdbError.timedOut(command: commandLine(executable, arguments)) }
        if handle.isCancelled { throw CancellationError() }
        return output
    }

    /// 串流輸出（逐行，`\r` 也視為換行，才能拿到 `adb push -p` 的進度列）。
    /// 結束碼非 0 時以 `AdbError.commandFailed` 結束串流；消費端停止迭代即終止子行程。
    public static func lines(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let handle = makeHandle(executable, arguments, environment: environment)
            continuation.onTermination = { _ in handle.cancel() }
            do {
                try handle.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let reader = handle.pipe.fileHandleForReading
                var pending = Data()
                var tail: [String] = []   // 失敗時附在錯誤訊息裡的最後幾行
                func emit(_ bytes: Data) {
                    let line = String(decoding: bytes, as: UTF8.self)
                    guard !line.isEmpty else { return }
                    tail.append(line)
                    if tail.count > 20 { tail.removeFirst() }
                    continuation.yield(line)
                }
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        emit(pending.subdata(in: pending.startIndex..<index))
                        pending.removeSubrange(pending.startIndex...index)
                    }
                }
                if !pending.isEmpty { emit(pending) }
                let status = handle.waitForExit()
                if handle.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else if status != 0 {
                    continuation.finish(throwing: AdbError.commandFailed(exitCode: status, output: tail.joined(separator: "\n")))
                } else {
                    continuation.finish()
                }
            }
        }
    }

    static func makeHandle(_ executable: String, _ arguments: [String], environment: [String: String]?) -> ProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        return ProcessHandle(process: process, pipe: pipe)
    }

    static func commandLine(_ executable: String, _ arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
