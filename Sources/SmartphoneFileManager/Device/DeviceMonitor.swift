import SFMCore
import SwiftUI

/// 裝置清單輪詢：Android（`adb devices -l`）、iPhone（`idevice_id -l`）與 MTP（libmtp 偵測 USB），每 3 秒一次。
///
/// `selectedSerial` 是工具列「裝置工具」（終端機、App、截圖…）的目標 Android 裝置；
/// 兩個檔案窗格各自選擇來源，與它無關。
/// 原版每次輪詢還會對每台裝置跑 `ip route` 查 Wi-Fi 狀態——裝置多時很貴，
/// 這版改為只在開啟「無線連線」面板時才查詢。
@MainActor
@Observable
final class DeviceMonitor {
    private(set) var devices: [AdbDeviceInfo] = []
    private(set) var iphones: [IPhoneDeviceInfo] = []
    private(set) var mtpDevices: [MTPDeviceInfo] = []
    /// MTP 裝置開啟失敗的訊息（例如被其他 app 佔用），顯示在 MTP 窗格的未連線畫面
    private(set) var mtpErrors: [String] = []
    var selectedSerial: String?
    /// adb 本身無法執行（找不到、權限）時的錯誤；有值時 UI 顯示設定提示
    private(set) var adbError: String?
    /// libimobiledevice 是否已安裝（未安裝時來源選單顯示安裝提示）
    private(set) var iphoneToolsInstalled = IPhoneFileSource.locateTool() != nil

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var iphoneNames: [String: String] = [:]

    var selectedDevice: AdbDeviceInfo? { devices.first { $0.serial == selectedSerial } }

    /// 工具列目標裝置的連線；未選取或狀態不是 `device`（如未授權）時為 nil
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
            if !devices.isEmpty { devices = [] }
            selectedSerial = nil
        }

        iphoneToolsInstalled = IPhoneFileSource.locateTool() != nil
        let phones = await IPhoneDeviceInfo.list(knownNames: iphoneNames)
        for phone in phones { iphoneNames[phone.udid] = phone.name }
        if phones != iphones { iphones = phones }

        let mtp = await MTPDeviceManager.shared.refresh()
        if mtp != mtpDevices { mtpDevices = mtp }
        let errors = MTPDeviceManager.shared.openErrors
        if errors != mtpErrors { mtpErrors = errors }
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
