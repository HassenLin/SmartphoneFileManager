import SFMCore
import SwiftUI

/// 工具列上的「裝置工具」按鈕：按下彈出視窗，內含目標裝置選擇與工具清單。
/// Android 與 iPhone 共用同一外觀；各自的工具清單由 `AndroidToolsContent`／`IPhoneToolsContent` 提供。
struct DeviceToolsButton<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let help: LocalizedStringKey
    /// 內容拿到一個「關閉彈出視窗後執行」的函式：先關掉 popover 再開 sheet／視窗，避免兩者同時呈現衝突
    @ViewBuilder let content: (_ perform: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void) -> Content
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: { Label(title, systemImage: systemImage).labelStyle(.titleAndIcon) }
            .help(help)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                content { action in
                    isPresented = false
                    Task { @MainActor in action() }
                }
                .padding(12)
                .frame(width: 280)
            }
    }
}

/// 彈出視窗中的一列工具
struct ToolRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
        .disabled(disabled)
    }
}

/// Android 工具：無線連線、終端機、App、裝置資訊、截圖、剪貼簿、鏡像
struct AndroidToolsContent: View {
    let app: AppModel
    let perform: (@escaping @MainActor @Sendable () -> Void) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var devices = app.devices
        let noDevice = app.devices.connection == nil
        VStack(alignment: .leading, spacing: 4) {
            Picker("Device", selection: $devices.selectedSerial) {
                if app.devices.devices.isEmpty { Text("No Android device").tag(String?.none) }
                ForEach(app.devices.devices) { device in
                    Text(device.isReady ? device.displayName : "\(device.displayName) — \(device.state)")
                        .tag(Optional(device.serial))
                }
            }
            .labelsHidden()
            Divider().padding(.vertical, 4)
            ToolRow(title: "Wireless Connection", systemImage: "wifi") { perform { app.sheet = .connect } }
            ToolRow(title: "ADB Terminal", systemImage: "terminal", disabled: noDevice) {
                perform { if app.openTerminal() { openWindow(id: "terminal") } }
            }
            ToolRow(title: "Apps", systemImage: "square.grid.3x3", disabled: noDevice) { perform { app.sheet = .appManager } }
            ToolRow(title: "Device Info", systemImage: "info.circle", disabled: noDevice) { perform { app.sheet = .deviceInfo } }
            ToolRow(title: "Screenshot (saved to Downloads)", systemImage: "camera", disabled: noDevice) {
                perform { app.takeScreenshot() }
            }
            ToolRow(title: "Send Text to Device Clipboard", systemImage: "doc.on.clipboard", disabled: noDevice) {
                perform { app.sheet = .clipboard }
            }
            ToolRow(title: "Screen Mirroring (scrcpy)", systemImage: "rectangle.on.rectangle", disabled: noDevice) {
                perform { app.startScreenMirror() }
            }
        }
    }
}

/// iPhone 工具：裝置資訊（含重新開機／關機）、App 管理
struct IPhoneToolsContent: View {
    let app: AppModel
    let perform: (@escaping @MainActor @Sendable () -> Void) -> Void

    var body: some View {
        @Bindable var devices = app.devices
        let noDevice = app.devices.selectedIPhone == nil
        VStack(alignment: .leading, spacing: 4) {
            Picker("Device", selection: $devices.selectedIPhoneUDID) {
                if app.devices.iphones.isEmpty { Text("No iPhone connected").tag(String?.none) }
                ForEach(app.devices.iphones) { phone in
                    Text(phone.network ? "\(phone.name) (Wi-Fi)" : phone.name).tag(Optional(phone.udid))
                }
            }
            .labelsHidden()
            if !app.devices.iphoneToolsInstalled {
                ToolRow(title: "Install libimobiledevice…", systemImage: "arrow.down.circle") {
                    perform { app.sheet = .setupGuide(.iphone) }
                }
            }
            Divider().padding(.vertical, 4)
            ToolRow(title: "Device Info", systemImage: "info.circle", disabled: noDevice) { perform { app.sheet = .iphoneInfo } }
            ToolRow(title: "Apps", systemImage: "square.grid.3x3", disabled: noDevice) { perform { app.sheet = .iphoneApps } }
        }
    }
}
