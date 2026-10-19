import SFMCore
import SwiftUI

/// 主視窗：左右兩個對等的檔案窗格（各自選擇 Mac／Android／iPhone；左窗格可收合），
/// 工具列放 Android／iPhone 工具按鈕（各自彈出目標裝置選擇與工具清單）。
struct MainWindowView: View {
    @Bindable var app: AppModel

    var body: some View {
        HSplitView {
            if !app.isLeftPaneCollapsed {
                BrowserPaneView(app: app, side: .left)
            }
            BrowserPaneView(app: app, side: .right)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 工作面板：底部、可收合（不擋操作）；衝突詢問以 sheet 顯示（與 app.sheet 分掛在不同 view 上）
        .safeAreaInset(edge: .bottom, spacing: 0) { TasksPanel(app: app) }
        .sheet(item: Binding(get: { app.queue.conflicts.first }, set: { _ in })) { conflict in
            ConflictSheet(conflict: conflict, queue: app.queue).interactiveDismissDisabled()
        }
        .overlay { ToastOverlay(center: app.toasts) }
        .toolbar { toolbar }
        .navigationTitle("Smartphone File Manager")
        // 裝置接上／拔除／授權狀態改變 → 更新兩窗格的來源可用性
        .onChange(of: app.devices.devices) { _, _ in app.refreshSources() }
        .onChange(of: app.needsAdb, initial: true) { _, _ in app.updateAdbWanted() }
        .onChange(of: app.devices.iphones) { _, _ in app.refreshSources() }
        .onChange(of: app.devices.mtpDevices) { _, _ in app.refreshSources() }
        .sheet(item: $app.sheet) { sheet in sheetContent(sheet) }
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
        // 同步（類似 rsync）：左右窗格目前的資料夾，彈出視窗設定專案名稱、方向與選項，見 SyncPopover.swift
        ToolbarItem(placement: .primaryAction) {
            SyncToolbarButton(app: app)
        }
        // Android／iPhone 工具各一顆按鈕，按下彈出視窗（目標裝置選擇＋工具清單），見 DeviceToolsPopover.swift
        ToolbarItemGroup(placement: .primaryAction) {
            DeviceToolsButton(title: "Android", systemImage: "candybarphone",
                              help: "Android tools (terminal, apps, screenshot…)") { perform in
                AndroidToolsContent(app: app, perform: perform)
            }
            DeviceToolsButton(title: "iPhone", systemImage: "iphone",
                              help: "iPhone tools (device info, apps…)") { perform in
                IPhoneToolsContent(app: app, perform: perform)
            }
        }
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
                guard let location = app.location(of: side) else { return }
                do { try app.bookmarks.addFolder(name: name, location: location) } catch { app.toasts.error(error) }
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
        case .iphoneInfo:
            IPhoneInfoView(app: app)
        case .iphoneApps:
            if let service = app.devices.iphoneService {
                IPhoneAppsView(model: IPhoneAppsModel(service: service, toasts: app.toasts))
            }
        case let .imagePreview(model):
            ImagePreviewView(model: model)
        case let .editor(model):
            EditorView(model: model)
        case let .setupGuide(topic):
            SetupGuideView(app: app, topic: topic)
        }
    }
}
