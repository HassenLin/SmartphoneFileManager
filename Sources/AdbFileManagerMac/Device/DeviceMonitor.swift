import AFMCore
import SwiftUI

/// 裝置清單輪詢（原版 `AdbDevicePoller` 的裝置部分）。
///
/// 每 3 秒 `adb devices -l` 一次。目前選取的裝置消失時自動改選第一台可用裝置。
/// 原版每次輪詢還會對每台裝置跑 `ip route` 查 Wi-Fi 狀態——這在裝置多時很貴，
/// 這版改為只在開啟「無線連線」面板時才查詢。
@MainActor
@Observable
final class DeviceMonitor {
    private(set) var devices: [AdbDeviceInfo] = []
    var selectedSerial: String?
    /// adb 本身無法執行（找不到、權限）時的錯誤；有值時 UI 顯示設定提示
    private(set) var adbError: String?

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var selectedDevice: AdbDeviceInfo? { devices.first { $0.serial == selectedSerial } }

    /// 目前可操作的裝置連線；未選取或狀態不是 `device`（如未授權）時為 nil
    var connection: DeviceConnection? {
        guard let device = selectedDevice, device.isReady else { return nil }
        return AdbClient.current.device(device.serial)
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await AdbClient.current.startServer()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        do {
            let list = try await AdbClient.current.devices()
            adbError = nil
            if list != devices { devices = list }
            if selectedSerial == nil || !list.contains(where: { $0.serial == selectedSerial }) {
                selectedSerial = list.first(where: \.isReady)?.serial ?? list.first?.serial
            }
        } catch {
            adbError = error.localizedDescription
            devices = []
            selectedSerial = nil
        }
    }

    /// 設定變更 adb 路徑後重新啟動 server
    func restartServer() {
        Task {
            _ = try? await AdbClient.current.run(["kill-server"], timeout: .seconds(10))
            await AdbClient.current.startServer()
            await refresh()
        }
    }
}
