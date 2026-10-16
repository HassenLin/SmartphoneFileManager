import SFMCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// iPhone 裝置資訊面板（對應 Android 的 `DeviceInfoView`）：機型、iOS、電池、儲存空間、重新開機／關機
struct IPhoneInfoView: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var info: IPhoneDetails?
    @State private var error: String?
    @State private var pendingPower: PowerAction?

    enum PowerAction: String, Identifiable {
        case restart, shutdown
        var id: String { rawValue }
        var title: String {
            self == .restart ? String(localized: "Restart iPhone") : String(localized: "Shut Down iPhone")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("iPhone Info").font(.headline)
                Spacer()
                Menu("Power") {
                    Button(PowerAction.restart.title) { pendingPower = .restart }
                    Button(PowerAction.shutdown.title) { pendingPower = .shutdown }
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
        .frame(width: 560, height: 520)
        .onAppear(perform: load)
        .confirmationDialog(pendingPower?.title ?? "",
                            isPresented: Binding(get: { pendingPower != nil }, set: { if !$0 { pendingPower = nil } })) {
            Button(pendingPower == .shutdown ? "Shut Down" : "Restart", role: .destructive) {
                if let action = pendingPower { power(action) }
            }
        }
    }

    private func load() {
        guard let service = app.devices.iphoneService else { error = String(localized: "No iPhone connected"); return }
        error = nil
        Task {
            do { info = try await service.details() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func power(_ action: PowerAction) {
        guard let service = app.devices.iphoneService else { return }
        let toasts = app.toasts
        Task {
            do {
                if action == .restart { try await service.restart() } else { try await service.shutdown() }
                toasts.success(String(localized: "Command sent"))
                dismiss()
            } catch {
                toasts.error(error)
            }
        }
    }

    private func details(_ info: IPhoneDetails) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Device") {
                row("Name", info.name)
                row("Model", info.productType)
                row("Model Number", info.modelNumber + info.region)
                row("iOS", "\(info.iosVersion) (\(info.buildVersion))")
                row("CPU", info.cpuArchitecture)
                row("Time Zone", info.timeZone)
            }
            section("Battery") {
                GridRow {
                    Text("Level").foregroundStyle(.secondary)
                    ProgressView(value: Double(max(0, info.batteryLevel)), total: 100) {
                        EmptyView()
                    } currentValueLabel: {
                        Text(info.batteryLevel >= 0 ? "\(info.batteryLevel)%" : "-")
                    }
                }
                row("Status", info.isCharging ? String(localized: "Charging")
                    : info.externalPower ? String(localized: "Not charging") : String(localized: "Discharging"))
            }
            section("Storage") {
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
}

/// iPhone App 管理狀態：清單、安裝 .ipa、解除安裝
@MainActor
@Observable
final class IPhoneAppsModel {
    private(set) var apps: [IPhoneInstalledApp] = []
    private(set) var loading = false
    var includeSystem = false { didSet { load() } }
    var filter = ""
    var selection: IPhoneInstalledApp.ID?
    var pendingUninstall: IPhoneInstalledApp?

    @ObservationIgnored private let service: IPhoneDeviceService
    @ObservationIgnored private let toasts: ToastCenter

    init(service: IPhoneDeviceService, toasts: ToastCenter) {
        self.service = service
        self.toasts = toasts
    }

    var visible: [IPhoneInstalledApp] {
        filter.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.bundleID.localizedCaseInsensitiveContains(filter)
        }
    }

    func load() {
        loading = true
        Task {
            defer { loading = false }
            do { apps = try await service.installedApps(includeSystem: includeSystem) }
            catch { toasts.error(error) }
        }
    }

    func installWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.prompt = String(localized: "Install")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(String(localized: "Installed \(url.lastPathComponent)")) { try await $0.install(ipa: url.path) }
    }

    func uninstall(_ app: IPhoneInstalledApp) {
        run(String(localized: "Uninstalled \(app.name)")) { try await $0.uninstall(app.bundleID) }
    }

    private func run(_ success: String, _ action: @escaping @MainActor (IPhoneDeviceService) async throws -> Void) {
        loading = true
        Task {
            do {
                try await action(service)
                toasts.success(success)
            } catch {
                toasts.error(error)
            }
            load()
        }
    }
}

struct IPhoneAppsView: View {
    @Bindable var model: IPhoneAppsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("iPhone Apps").font(.headline)
                Spacer()
                Toggle("Include system apps", isOn: $model.includeSystem)
                TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Install IPA…") { model.installWithPanel() }
                Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            Table(model.visible, selection: $model.selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Bundle ID", value: \.bundleID)
                TableColumn("Version", value: \.version).width(80)
            }
            .contextMenu(forSelectionType: IPhoneInstalledApp.ID.self) { ids in
                if let id = ids.first, let app = model.apps.first(where: { $0.id == id }) {
                    Button("Copy Bundle ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.bundleID, forType: .string)
                    }
                    Button("Uninstall…", role: .destructive) { model.pendingUninstall = app }
                }
            }
            .overlay { if model.loading { ProgressView() } }
            Divider()
            Text("\(model.visible.count) apps").font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 480, idealHeight: 600)
        .onAppear { model.load() }
        .confirmationDialog("Uninstall \(model.pendingUninstall?.name ?? "")?",
                            isPresented: Binding(get: { model.pendingUninstall != nil }, set: { if !$0 { model.pendingUninstall = nil } })) {
            Button("Uninstall", role: .destructive) {
                if let app = model.pendingUninstall { model.uninstall(app) }
            }
        }
    }
}
