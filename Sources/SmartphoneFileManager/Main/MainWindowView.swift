import SFMCore
import SwiftUI

/// 主視窗：左右兩個對等的檔案窗格（各自選擇 Mac／Android／iPhone；左窗格可收合），
/// 工具列放「裝置工具」的目標 Android 裝置與各項工具。
struct MainWindowView: View {
    @Bindable var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            if !app.isLeftPaneCollapsed {
                BrowserPaneView(app: app, side: .left)
            }
            BrowserPaneView(app: app, side: .right)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { ToastOverlay(center: app.toasts) }
        .toolbar { toolbar }
        .navigationTitle("Smartphone File Manager")
        // 裝置接上／拔除／授權狀態改變 → 更新兩窗格的來源可用性
        .onChange(of: app.devices.devices) { _, _ in app.refreshSources() }
        .onChange(of: app.devices.iphones) { _, _ in app.refreshSources() }
        .sheet(item: $app.sheet) { sheet in sheetContent(sheet) }
        .sheet(isPresented: Binding(get: { app.transfers.isBusy }, set: { _ in })) {
            TransferProgressView(center: app.transfers).interactiveDismissDisabled()
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(
            get: { app.pendingDeletion != nil }, set: { if !$0 { app.pendingDeletion = nil } })
        ) {
            Button(app.pendingDeletion?.toTrash == true ? "Move to Trash" : "Delete", role: .destructive) {
                app.confirmDelete()
            }
        } message: {
            if app.pendingDeletion?.toTrash != true { Text("This cannot be undone.") }
        }
        .confirmationDialog("Install \(app.pendingInstall?.item.name ?? "")?", isPresented: Binding(
            get: { app.pendingInstall != nil }, set: { if !$0 { app.pendingInstall = nil } })
        ) {
            Button("Install") {
                if let pending = app.pendingInstall { app.install(pending.item, in: pending.side) }
            }
        }
    }

    private var deletionTitle: String {
        guard let pending = app.pendingDeletion else { return "" }
        let location = app.title(for: app.pane(pending.side).sourceID)
        if pending.toTrash {
            return pending.items.count == 1
                ? String(localized: "Move “\(pending.items[0].name)” to the Trash?")
                : String(localized: "Move \(pending.items.count) items to the Trash?")
        }
        return pending.items.count == 1
            ? String(localized: "Delete “\(pending.items[0].name)” from \(location)?")
            : String(localized: "Delete \(pending.items.count) items from \(location)?")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { app.isLeftPaneCollapsed.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(app.isLeftPaneCollapsed ? "Show Left Pane" : "Hide Left Pane")
        }
        ToolbarItem(placement: .principal) {
            devicePicker
        }
        ToolbarItemGroup(placement: .primaryAction) {
            let noDevice = app.devices.connection == nil
            Button { app.sheet = .connect } label: { Label("Wireless", systemImage: "wifi") }
                .help("Wireless Connection")
            Button { if app.openTerminal() { openWindow(id: "terminal") } } label: { Label("Terminal", systemImage: "terminal") }
                .help("ADB Terminal")
                .disabled(noDevice)
            Button { app.sheet = .appManager } label: { Label("Apps", systemImage: "square.grid.3x3") }
                .help("Apps")
                .disabled(noDevice)
            Button { app.sheet = .deviceInfo } label: { Label("Device Info", systemImage: "info.circle") }
                .help("Device Info")
                .disabled(noDevice)
            Button { app.takeScreenshot() } label: { Label("Screenshot", systemImage: "camera") }
                .help("Screenshot (saved to Downloads)")
                .disabled(noDevice)
            Button { app.sheet = .clipboard } label: { Label("Clipboard", systemImage: "doc.on.clipboard") }
                .help("Send Text to Device Clipboard")
                .disabled(noDevice)
            Button { app.startScreenMirror() } label: { Label("Mirror", systemImage: "rectangle.on.rectangle") }
                .help("Screen Mirroring (scrcpy)")
                .disabled(noDevice)
        }
    }

    /// 裝置工具（終端機、App、截圖…）的目標 Android 裝置
    private var devicePicker: some View {
        @Bindable var devices = app.devices
        return Picker("Device tools", selection: $devices.selectedSerial) {
            if app.devices.devices.isEmpty {
                Text("No Android device").tag(String?.none)
            }
            ForEach(app.devices.devices) { device in
                Text(device.isReady ? device.displayName : "\(device.displayName) — \(device.state)")
                    .tag(Optional(device.serial))
            }
        }
        .frame(minWidth: 240)
        .help("Android device used by the toolbar tools (terminal, apps, screenshot…)")
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case let .newFolder(side):
            TextInputSheet(title: "New Folder", prompt: "Folder name", confirmTitle: "Create", text: "") {
                app.pane(side).makeDirectory($0)
            }
        case let .newFile(side):
            NewFileSheet { app.pane(side).createFile($0, contents: $1) }
        case let .rename(side, item):
            TextInputSheet(title: "Rename", prompt: "New name", confirmTitle: "Rename", text: item.name) {
                app.pane(side).rename(item, to: $0)
            }
        case let .permissions(side, item):
            PermissionsSheet(file: item) { app.pane(side).changeMode(item, mode: $0) }
        case let .addBookmark(side):
            TextInputSheet(title: "Bookmark This Folder", prompt: "Name", confirmTitle: "Add",
                           text: RemotePath.name(of: app.pane(side).path)) { name in
                do { try app.bookmarks.add(name: name, path: app.pane(side).path) } catch { app.toasts.error(error) }
            }
        case let .search(side):
            SearchSheet(app: app, side: side)
        case .clipboard:
            ClipboardSheet(app: app)
        case .connect:
            ConnectSheet(app: app)
        case .deviceInfo:
            DeviceInfoView(app: app)
        case .appManager:
            if let connection = app.devices.connection {
                AppManagerView(model: AppManagerModel(service: AppPackageService(device: connection), toasts: app.toasts))
            }
        case let .imagePreview(model):
            ImagePreviewView(model: model)
        case let .editor(model):
            EditorView(model: model)
        }
    }
}
