import CLibMTP
import Foundation

/// MTP 裝置偵測與 session 生命週期。
///
/// - `refresh()` 由 UI 的裝置輪詢呼叫：偵測 USB 上的 MTP 裝置，新出現的開啟 session、消失的釋放。
/// - 已開啟的裝置以 USB 位置（bus:devnum）辨識，不會每次輪詢重開（重開會中斷進行中的傳輸）。
/// - 開啟失敗（常見原因：Android File Transfer、OpenMTP、「影像擷取」正佔用裝置，或手機未選「檔案傳輸」模式）
///   記錄在 `openErrors`，15 秒後才重試，避免每 3 秒反覆搶裝置。
public final class MTPDeviceManager: @unchecked Sendable {
    public static let shared = MTPDeviceManager()

    /// 偵測用的序列佇列（與各裝置 session 的佇列分開，大檔傳輸時仍可偵測插拔）
    private let queue = DispatchQueue(label: "mtp.detect")
    private let lock = NSLock()
    private var sessions: [String: MTPSession] = [:]          // location → session
    private var failedAt: [String: Date] = [:]                // location → 上次開啟失敗時間
    private var lastErrors: [String: String] = [:]            // location → 訊息

    public var openErrors: [String] { lock.withLock { Array(lastErrors.values) } }

    public func session(serial: String) -> MTPSession? {
        lock.withLock { sessions.values.first { $0.serial == serial } }
    }

    /// 已開啟裝置的檔案來源；未連線或 libmtp 不可用時為 nil
    public func source(serial: String) -> (any FileSource)? {
        guard MTP.isAvailable else { return nil }
        return session(serial: serial).map(MTPFileSource.init(session:))
    }

    public func refresh() async -> [MTPDeviceInfo] {
        guard MTP.isAvailable else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.detect()) }
        }
    }

    private func detect() -> [MTPDeviceInfo] {
        var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let status = LIBMTP_Detect_Raw_Devices(&raw, &count)
        defer { free(raw) }
        var present: [String: LIBMTP_raw_device_t] = [:]
        if status == LIBMTP_ERROR_NONE, let raw {
            for index in 0..<Int(count) {
                let device = raw[index]
                present["\(device.bus_location):\(device.devnum)"] = device
            }
        }

        // 拔除：釋放 session
        let gone = lock.withLock { sessions.filter { present[$0.key] == nil } }
        for (location, session) in gone {
            session.release()
            lock.withLock { _ = sessions.removeValue(forKey: location) }
        }
        lock.withLock {
            failedAt = failedAt.filter { present[$0.key] != nil }
            lastErrors = lastErrors.filter { present[$0.key] != nil }
        }

        // 新裝置：開啟（Uncached：不預先抓整棵檔案樹，大容量裝置也能秒開）
        for (location, var device) in present where lock.withLock({ sessions[location] == nil }) {
            if let failed = lock.withLock({ failedAt[location] }), Date().timeIntervalSince(failed) < 15 { continue }
            if let handle = LIBMTP_Open_Raw_Device_Uncached(&device) {
                let session = MTPSession(device: handle, location: location)
                lock.withLock {
                    sessions[location] = session
                    failedAt[location] = nil
                    lastErrors[location] = nil
                }
            } else {
                let product = device.device_entry.product.map { String(cString: $0) } ?? location
                lock.withLock {
                    failedAt[location] = Date()
                    lastErrors[location] = String(localized:
                        "Cannot open MTP device \(product). Close Android File Transfer, OpenMTP or Image Capture, and choose “File transfer” on the device.")
                }
            }
        }
        return lock.withLock {
            sessions.values.map { MTPDeviceInfo(serial: $0.serial, name: $0.name) }.sorted { $0.name < $1.name }
        }
    }
}
