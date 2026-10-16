import AFMCore
import SwiftUI

/// 裝置資訊面板（原版 DeviceInfoDialog）
struct DeviceInfoView: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var info: DeviceDetails?
    @State private var error: String?
    @State private var pendingReboot: RebootMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Device Info").font(.headline)
                Spacer()
                Menu("Reboot") {
                    ForEach(RebootMode.allCases) { mode in
                        Button(title(for: mode)) { pendingReboot = mode }
                    }
                }
                .fixedSize()
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            Group {
                if let info {
                    ScrollView { details(info).padding(16) }
                } else if let error {
                    ContentUnavailableView("Cannot read device info", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 560, height: 560)
        .onAppear(perform: load)
        .confirmationDialog(pendingReboot.map(title(for:)) ?? "",
                            isPresented: Binding(get: { pendingReboot != nil }, set: { if !$0 { pendingReboot = nil } })) {
            Button("Reboot", role: .destructive) {
                if let mode = pendingReboot { app.reboot(mode) }
            }
        }
    }

    private func title(for mode: RebootMode) -> String {
        switch mode {
        case .normal: return String(localized: "Reboot")
        case .recovery: return String(localized: "Reboot to Recovery")
        case .bootloader: return String(localized: "Reboot to Bootloader")
        }
    }

    private func load() {
        guard let connection = app.devices.connection else { error = AdbError.noDevice.localizedDescription; return }
        error = nil
        Task {
            do { info = try await DeviceInfoService(device: connection).details() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func details(_ info: DeviceDetails) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Device") {
                row("Model", info.model)
                row("Manufacturer", info.manufacturer)
                row("Brand", info.brand)
                row("Product", info.deviceName)
                row("Android", "\(info.androidVersion) (API \(info.sdkInt))")
                row("ABI", info.abi)
                row("Screen", "\(info.screenSize) @ \(info.density) dpi")
                row("Root", info.isRooted ? String(localized: "Yes") : String(localized: "No"))
            }
            section("Battery") {
                GridRow {
                    Text("Level").foregroundStyle(.secondary)
                    ProgressView(value: Double(max(0, info.battery.percentage)), total: 100) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(info.battery.percentage)%")
                    }
                }
                row("Status", batteryStatus(info.battery.status))
                row("Health", batteryHealth(info.battery.health))
                row("Power", powerSource(info.battery))
                row("Temperature", String(format: "%.1f °C", info.battery.temperatureCelsius))
                row("Voltage", "\(info.battery.voltageMillivolts) mV")
            }
            section("Storage (/data)") {
                GridRow {
                    Text("Used").foregroundStyle(.secondary)
                    ProgressView(value: info.storage.usedFraction) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(ByteFormat.string(info.storage.usedBytes)) / \(ByteFormat.string(info.storage.totalBytes))")
                    }
                }
                row("Free", ByteFormat.string(info.storage.freeBytes))
            }
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) { content() }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value).textSelection(.enabled)
        }
    }

    // Android BatteryManager 常數 → 顯示文字
    private func batteryStatus(_ code: Int) -> String {
        switch code {
        case 2: return String(localized: "Charging")
        case 3: return String(localized: "Discharging")
        case 4: return String(localized: "Not charging")
        case 5: return String(localized: "Full")
        default: return String(localized: "Unknown")
        }
    }

    private func batteryHealth(_ code: Int) -> String {
        switch code {
        case 2: return String(localized: "Good")
        case 3: return String(localized: "Overheat")
        case 4: return String(localized: "Dead")
        case 5: return String(localized: "Over voltage")
        case 6: return String(localized: "Failure")
        case 7: return String(localized: "Cold")
        default: return String(localized: "Unknown")
        }
    }

    private func powerSource(_ battery: BatteryInfo) -> String {
        if battery.acPowered { return String(localized: "AC") }
        if battery.usbPowered { return String(localized: "USB") }
        if battery.wirelessPowered { return String(localized: "Wireless") }
        return String(localized: "Battery")
    }
}
