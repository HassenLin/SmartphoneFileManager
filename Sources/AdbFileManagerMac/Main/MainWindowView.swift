import AFMCore
import SwiftUI

/// 主視窗：左本機、右裝置的雙窗格（本機窗格可收合），工具列放裝置選擇與裝置工具。
struct MainWindowView: View {
    @Bindable var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            if !app.isLocalPaneCollapsed {
                LocalPaneView(app: app)
            }
            RemotePaneView(app: app)
        }
        .overlay { ToastOverlay(center: app.toasts) }
        .toolbar { toolbar }
        .navigationTitle("ADB File Manager")
        .onChange(of: app.devices.selectedSerial) { _, _ in app.remote.deviceChanged() }
        .onChange(of: app.devices.connection) { old, new in
            // 同一台裝置從 unauthorized 變成可用時也要重新載入
            if old == nil, new != nil { app.remote.reload() }
        }
        .sheet(item: $app.sheet) { sheet in sheetContent(sheet) }
        .sheet(isPresented: Binding(get: { app.transfers.isBusy }, set: { _ in })) {
            TransferProgressView(center: app.transfers).interactiveDismissDisabled()
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(
            get: { !app.pendingDeletion.isEmpty }, set: { if !$0 { app.pendingDeletion = [] } })
        ) {
            Button("Delete", role: .destructive) { app.remote.delete(app.pendingDeletion) }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog("Install \(app.pendingInstall?.name ?? "")?", isPresented: Binding(
            get: { app.pendingInstall != nil }, set: { if !$0 { app.pendingInstall = nil } })
        ) {
            Button("Install") { if let file = app.pendingInstall { app.remote.installApk(file) } }
        }
    }

    private var deletionTitle: String {
        app.pendingDeletion.count == 1
            ? String(localized: "Delete “\(app.pendingDeletion[0].name)” from the device?")
            : String(localized: "Delete \(app.pendingDeletion.count) items from the device?")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { app.isLocalPaneCollapsed.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(app.isLocalPaneCollapsed ? "Show Mac Pane" : "Hide Mac Pane")
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

    private var devicePicker: some View {
        @Bindable var devices = app.devices
        return Picker("Device", selection: $devices.selectedSerial) {
            if app.devices.devices.isEmpty {
                Text("No device").tag(String?.none)
            }
            ForEach(app.devices.devices) { device in
                Text(device.isReady ? device.displayName : "\(device.displayName) — \(device.state)")
                    .tag(Optional(device.serial))
            }
        }
        .frame(minWidth: 240)
        .help("Android Device")
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .newFolder:
            TextInputSheet(title: "New Folder", prompt: "Folder name", confirmTitle: "Create", text: "") {
                app.remote.makeDirectory($0)
            }
        case .newFile:
            NewFileSheet { app.remote.createFile($0, contents: $1) }
        case let .rename(file):
            TextInputSheet(title: "Rename", prompt: "New name", confirmTitle: "Rename", text: file.name) {
                app.remote.rename(file, to: $0)
            }
        case let .permissions(file):
            PermissionsSheet(file: file) { app.remote.changeMode(file, mode: $0) }
        case let .copyMove(files, move):
            CopyMoveSheet(files: files, move: move, initialPath: app.remote.path) {
                app.remote.copyOrMove(files, to: $0, move: move)
            }
        case .addBookmark:
            TextInputSheet(title: "Bookmark This Folder", prompt: "Name", confirmTitle: "Add",
                           text: RemotePath.name(of: app.remote.path)) { name in
                do { try app.bookmarks.add(name: name, path: app.remote.path) } catch { app.toasts.error(error) }
            }
        case .search:
            SearchSheet(app: app)
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
