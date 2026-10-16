import AFMCore
import AppKit
import SwiftUI

/// App 管理狀態（原版 AppManagerDialog）
@MainActor
@Observable
final class AppManagerModel {
    private(set) var packages: [AppPackage] = []
    private(set) var loading = false
    private(set) var details: [String: AppPackageDetails] = [:]
    var includeSystem = false { didSet { load() } }
    var filter = ""
    var selection: AppPackage.ID?
    var pendingUninstall: AppPackage?
    var pendingClear: AppPackage?

    @ObservationIgnored private let service: AppPackageService
    @ObservationIgnored private let toasts: ToastCenter

    init(service: AppPackageService, toasts: ToastCenter) {
        self.service = service
        self.toasts = toasts
    }

    var visible: [AppPackage] {
        filter.isEmpty ? packages : packages.filter { $0.packageName.localizedCaseInsensitiveContains(filter) }
    }

    func load() {
        loading = true
        Task {
            defer { loading = false }
            do {
                packages = try await service.listPackages(includeSystem: includeSystem)
            } catch {
                toasts.error(error)
            }
        }
    }

    func loadDetails(_ packageName: String) {
        guard details[packageName] == nil else { return }
        Task {
            if let info = try? await service.details(packageName) { details[packageName] = info }
        }
    }

    func run(_ success: String, reload: Bool = false, _ action: @escaping @MainActor (AppPackageService) async throws -> Void) {
        Task {
            do {
                try await action(service)
                toasts.success(success)
                if reload { load() }
            } catch {
                toasts.error(error)
            }
        }
    }

    func backup(_ package: AppPackage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(package.packageName).apk"
        panel.allowedContentTypes = [.init(filenameExtension: "apk") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(String(localized: "Backup saved: \(url.lastPathComponent)")) { try await $0.backupApk(package.packageName, to: url) }
    }
}

struct AppManagerView: View {
    @Bindable var model: AppManagerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps").font(.headline)
                Spacer()
                Toggle("Include system apps", isOn: $model.includeSystem)
                TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            HSplitView {
                List(model.visible, selection: $model.selection) { package in
                    HStack {
                        Image(systemName: package.isSystem ? "gearshape" : "app")
                            .foregroundStyle(package.isDisabled ? Color.secondary : Color.accentColor)
                        Text(package.packageName)
                            .foregroundStyle(package.isDisabled ? .secondary : .primary)
                        if package.isDisabled { Text("Disabled").font(.caption).foregroundStyle(.orange) }
                    }
                    .tag(package.id)
                    .contextMenu { actions(for: package) }
                }
                .frame(minWidth: 320)
                .overlay { if model.loading { ProgressView() } }

                detailPane.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Text("\(model.visible.count) apps · App names and icons are not shown in the macOS version (package names only).")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 480, idealHeight: 600)
        .onAppear { model.load() }
        .onChange(of: model.selection) { _, id in if let id { model.loadDetails(id) } }
        .confirmationDialog("Uninstall \(model.pendingUninstall?.packageName ?? "")?",
                            isPresented: Binding(get: { model.pendingUninstall != nil }, set: { if !$0 { model.pendingUninstall = nil } })) {
            Button("Uninstall", role: .destructive) {
                if let package = model.pendingUninstall {
                    model.run(String(localized: "Uninstalled \(package.packageName)"), reload: true) { try await $0.uninstall(package.packageName) }
                }
            }
        }
        .confirmationDialog("Clear all data of \(model.pendingClear?.packageName ?? "")?",
                            isPresented: Binding(get: { model.pendingClear != nil }, set: { if !$0 { model.pendingClear = nil } })) {
            Button("Clear Data", role: .destructive) {
                if let package = model.pendingClear {
                    model.run(String(localized: "Data cleared")) { try await $0.clearData(package.packageName) }
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = model.selection, let package = model.packages.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(package.packageName).font(.title3).textSelection(.enabled)
                    if let info = model.details[id] {
                        Grid(alignment: .leading, verticalSpacing: 6) {
                            row("Version", info.versionName.map { "\($0) (\(info.versionCode ?? "-"))" })
                            row("Target SDK", info.targetSdk)
                            row("Installed", info.firstInstallTime)
                            row("Updated", info.lastUpdateTime)
                            row("Path", info.apkPath)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) { actions(for: package) }
                        .buttonStyle(.link)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select an app", systemImage: "app.dashed")
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value ?? "-").textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func actions(for package: AppPackage) -> some View {
        let name = package.packageName
        Button("Launch") { model.run(String(localized: "Launch command sent")) { try await $0.launch(name) } }
        Button("Force Stop") { model.run(String(localized: "Stopped \(name)")) { try await $0.forceStop(name) } }
        Button("Back Up APK…") { model.backup(package) }
        if package.isDisabled {
            Button("Enable") { model.run(String(localized: "Enabled"), reload: true) { try await $0.setEnabled(name, enabled: true) } }
        } else {
            Button("Disable") { model.run(String(localized: "Disabled"), reload: true) { try await $0.setEnabled(name, enabled: false) } }
        }
        Button("Clear Data…", role: .destructive) { model.pendingClear = package }
        Button("Uninstall…", role: .destructive) { model.pendingUninstall = package }
    }
}
