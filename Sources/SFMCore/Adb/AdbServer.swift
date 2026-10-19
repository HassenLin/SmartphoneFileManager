import Foundation

/// adb 伺服器的擁有權：**只有本 app 啟動的伺服器，app 結束時才關閉**。
///
/// adb 伺服器（`adb fork-server`）是所有 adb 用戶端共用的常駐行程——Android Studio、終端機裡的 `adb`
/// 都連同一個（預設 127.0.0.1:5037）。app 結束時一律 `kill-server` 會讓那些工具一起斷線；
/// 一律不關又會讓 app 啟動的伺服器在 app 結束後一直留著。
///
/// 判斷方式：每次執行 adb 指令前（`AdbClient.run`）探測伺服器埠；當時沒有伺服器在聽，
/// 這個指令就會把它帶起來（adb 用戶端會自動啟動伺服器）→ 記為 app 啟動的。`kill-server` 之後清除記錄。
public enum AdbServer {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var startedByApp = false
    }

    private static let state = State()

    /// 伺服器埠：與 adb 相同，可由環境變數 `ANDROID_ADB_SERVER_PORT` 覆寫
    public static var port: UInt16 {
        ProcessInfo.processInfo.environment["ANDROID_ADB_SERVER_PORT"].flatMap(UInt16.init) ?? 5037
    }

    /// 是否已有 adb 伺服器在聽（連 localhost，沒有人聽時立即被拒，不會卡住）
    public static func isRunning(port: UInt16 = AdbServer.port) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// 不需要（也不會啟動）伺服器的指令
    private static let serverlessCommands: Set<String> = ["version", "help", "--version"]

    public static var startedByApp: Bool { state.lock.withLock { state.startedByApp } }

    /// `AdbClient.run` 執行指令前呼叫：沒有伺服器時，這個指令會啟動它
    static func willRun(_ arguments: [String]) {
        if arguments.first == "kill-server" {
            state.lock.withLock { state.startedByApp = false }
        } else if !serverlessCommands.contains(arguments.first ?? ""), !isRunning() {
            state.lock.withLock { state.startedByApp = true }
        }
    }

    /// app 結束時呼叫（同步、最多等 3 秒）：伺服器是 app 啟動的才關閉，別的工具啟動的不動
    public static func shutdownIfStartedByApp(executable: String) {
        guard startedByApp, FileManager.default.isExecutableFile(atPath: executable) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["kill-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        state.lock.withLock { state.startedByApp = false }
    }
}
