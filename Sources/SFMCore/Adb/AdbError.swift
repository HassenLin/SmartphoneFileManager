import Foundation

/// ADB 相關錯誤。對應原 Kotlin 版 `AdbException` 家族，收斂成單一 enum。
public enum AdbError: LocalizedError, Equatable {
    /// 指令結束碼非 0；`output` 為合併後的輸出（stdout + stderr）
    case commandFailed(exitCode: Int32, output: String)
    case timedOut(command: String)
    case noDevice
    case executableNotFound(String)
    case cannotOpenDirectory(String)
    case invalidArgument(String)
    case unexpectedOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(code, output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? String(localized: "Command failed (exit code \(Int(code)))")
                : String(localized: "Command failed (exit code \(Int(code))): \(detail)")
        case let .timedOut(command):
            return String(localized: "Command timed out: \(command)")
        case .noDevice:
            return String(localized: "No Android device connected")
        case let .executableNotFound(path):
            return String(localized: "Executable not found: \(path)")
        case let .cannotOpenDirectory(path):
            return String(localized: "Cannot open directory: \(path)")
        case let .invalidArgument(message):
            return message
        case let .unexpectedOutput(output):
            return String(localized: "Unexpected output: \(output)")
        }
    }
}
