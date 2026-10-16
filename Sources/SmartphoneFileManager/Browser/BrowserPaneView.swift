import SFMCore
import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// 檔案窗格（左右共用）：來源選單、路徑列、檔案表格、狀態列。
///
/// 鍵盤：表格取得焦點時 ⌘C 拷貝、⌘X 剪下、⌘V 貼上、Delete 刪除（SwiftUI 的
/// copy/cut/paste/delete command 只在焦點於表格時觸發，不影響篩選欄等文字輸入的剪貼簿）。
struct BrowserPaneView: View {
    @Bindable var app: AppModel
    let side: PaneSide
    /// 藍框狀態（見 `DropTargetState`：不可用窗格的 @State Bool，否則藍框一變整個窗格重算）
    @State private var dropState = DropTargetState()

    private var model: BrowserModel { app.pane(side) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { DropHighlightOverlay(state: dropState) }
                .onDrop(of: [.afmItems, .fileURL], delegate: PaneDropDelegate(app: app, side: side, highlight: dropState))
            Divider()
            statusBar
        }
        // HSplitView 不會自動把子視圖撐滿高度，必須明確給 maxHeight
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        // 選取變動＝使用者正在操作這個窗格（選單列指令的目標）
        .onChange(of: model.selection) { _, _ in app.activeSide = side }
    }

    // MARK: 標題列

    private var header: some View {
        @Bindable var model = model
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                sourceMenu
                Spacer()
                TextField("Filter", text: $model.filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
            }
            HStack(spacing: 4) {
                Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                    .help("Parent Folder")
                    .disabled(model.path == "/")
                Button { model.goHome() } label: { Image(systemName: "house") }
                    .help("Home Folder")
                PathBar(components: pathComponents, onSelect: { model.navigate(to: $0) },
                        onSubmit: { model.go(toTyped: $0) }, fullPath: model.path)
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                // 新增資料夾也可用選單列 ⇧⌘N（作用在最後操作的窗格，`AppModel.activeSide`）
                Menu {
                    Button("New Folder…") { app.sheet = .newFolder(side) }
                    Button("New File…") { app.sheet = .newFile(side) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New")
                if model.sourceID != nil { bookmarkMenu }
                if model.sourceID == .mac {
                    macLocationsMenu
                    Button { NSWorkspace.shared.activateFileViewerSelecting(model.selectedFiles.isEmpty
                        ? [URL(fileURLWithPath: model.path)] : model.selectedFiles.map { URL(fileURLWithPath: $0.path) })
                    } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                }
                SortMenu(sortType: $model.sortType)
                if model.capabilities.search {
                    Button { app.sheet = .search(side) } label: { Image(systemName: "magnifyingglass") }
                        .help("Search Subfolders")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.source == nil)
        }
        .padding(8)
    }

    /// 來源選單：這台 Mac、各 Android 裝置、各 iPhone（同一台裝置可在兩個窗格同時開啟）
    private var sourceMenu: some View {
        Menu {
            ForEach(app.sourceOptions) { option in
                Button {
                    app.selectSource(option.id, for: side)
                } label: {
                    Label(option.title, systemImage: option.id == model.sourceID ? "checkmark" : option.symbol)
                }
                .disabled(!option.enabled)
            }
            Divider()
            if !app.devices.iphoneToolsInstalled {
                Button("Set Up iPhone Access…") { app.sheet = .setupGuide(.iphone) }
            }
            Button("Setup Guide…") { app.sheet = .setupGuide(app.devices.adbError != nil ? .android : .iphone) }
        } label: {
            Label(app.title(for: model.sourceID), systemImage: app.symbol(for: model.sourceID))
                .font(.headline)
        }
        // 有框按鈕：左右窗格都看得出「這裡可以切換 Mac／Android／iPhone」
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Choose what this pane shows")
    }

    private var pathComponents: [(title: String, target: String)] {
        var result: [(String, String)] = [("/", "/")]
        var current = ""
        for part in RemotePath.components(model.path) {
            current += "/" + part
            result.append((model.displayNames[current] ?? part, current))
        }
        return result
    }

    /// Mac 窗格的位置捷徑：常用資料夾、iCloud／Google Drive／OneDrive 等雲端硬碟（藏在 ~/Library 下）、磁碟
    private var macLocationsMenu: some View {
        Menu {
            let locations = MacFileSource.locations()
            ForEach([MacLocation.Kind.folder, .cloud, .volume], id: \.self) { kind in
                let group = locations.filter { $0.kind == kind }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { location in
                            Button { model.navigate(to: location.path) } label: {
                                Label(location.name, systemImage: kind == .cloud ? "icloud" : kind == .volume ? "externaldrive" : "folder")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "icloud")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Locations (cloud drives, volumes)")
    }

    /// 書籤選單（兩種）：資料夾書籤（任何來源）、同步專案（左右一對資料夾）
    /// 書籤選單（兩種）：資料夾書籤、同步專案（左右一對資料夾）。
    /// 只列窗格目前裝置的項目（同步專案：任一邊在此裝置）；其他裝置的收在「其他裝置」子選單，
    /// 未連線裝置的書籤仍可開啟或刪除。
    private var bookmarkMenu: some View {
        let here = app.location(of: side)
        let current = here.flatMap { app.bookmarks.folderBookmark(at: $0) }
        let device = model.sourceID
        let folders = app.bookmarks.folders
        let projects = app.bookmarks.syncProjects
        let mine = folders.filter { device.map($0.location.belongs(to:)) ?? false }
        let myProjects = projects.filter { device.map($0.involves) ?? false }
        let otherFolders = folders.filter { bookmark in !mine.contains { $0.id == bookmark.id } }
        let otherProjects = projects.filter { project in !myProjects.contains { $0.id == project.id } }
        return Menu {
            if let current {
                Button("Remove Bookmark for This Folder") { try? app.bookmarks.removeFolder(current) }
            } else {
                Button("Bookmark This Folder…") { app.sheet = .addBookmark(side) }
            }
            if !mine.isEmpty {
                Section("Bookmarks") { ForEach(mine) { folderItem($0) } }
            }
            Section("Sync Projects") {
                ForEach(myProjects) { projectItem($0) }
                Button("New Sync Project…") {
                    app.syncProjectToEdit = nil
                    app.isSyncPopoverPresented = true
                }
            }
            if !otherFolders.isEmpty || !otherProjects.isEmpty {
                Divider()
                Menu("Other Devices (\(otherFolders.count + otherProjects.count))") {
                    if !otherFolders.isEmpty {
                        Section("Bookmarks") { ForEach(otherFolders) { folderItem($0) } }
                    }
                    if !otherProjects.isEmpty {
                        Section("Sync Projects") { ForEach(otherProjects) { projectItem($0) } }
                    }
                }
            }
        } label: {
            Image(systemName: current != nil ? "bookmark.fill" : "bookmark")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bookmarks and sync projects")
    }

    private func folderItem(_ bookmark: FolderBookmark) -> some View {
        Menu {
            Button("Open \(bookmark.location.path)") { app.open(bookmark.location, in: side) }
            Button("Delete Bookmark", role: .destructive) { try? app.bookmarks.removeFolder(bookmark) }
        } label: {
            Label(bookmark.name, systemImage: app.symbol(for: bookmark.location.source))
        } primaryAction: {
            app.open(bookmark.location, in: side)
        }
    }

    private func projectItem(_ project: SyncProject) -> some View {
        Menu {
            Button("Open…") { app.openSyncProject(project) }
            Button("Delete Sync Project", role: .destructive) { try? app.bookmarks.removeSyncProject(project) }
        } label: {
            Label(project.name, systemImage: "arrow.triangle.2.circlepath")
        } primaryAction: {
            app.openSyncProject(project)
        }
    }

    // MARK: 內容

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .noSource:
            ContentUnavailableView {
                Label("Choose a source", systemImage: "externaldrive.connected.to.line.below")
            } description: {
                Text("Pick This Mac, an Android device or an iPhone from the menu above.")
            }
        case .unavailable:
            unavailableView
        case let .failed(message):
            ContentUnavailableView {
                Label("Cannot open folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Go to Parent Folder") { model.goUp() }
                Button("Retry") { model.reload() }
                if model.sourceID == .mac {
                    Button("Choose Folder…") { chooseMacFolder() }
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                    }
                }
            }
        case .loading, .loaded:
            table.overlay {
                if model.phase == .loading { ProgressView() }
                else if model.visibleFiles.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private var unavailableView: some View {
        switch model.sourceID?.kind {
        case .android:
            if let error = app.devices.adbError {
                ContentUnavailableView {
                    Label("ADB is not available", systemImage: "wrench.and.screwdriver")
                } description: { Text(error) } actions: {
                    Button("Setup Guide…") { app.sheet = .setupGuide(.android) }
                    SettingsLink { Text("Open Settings…") }
                }
            } else {
                let device = app.devices.devices.first { $0.serial == model.sourceID?.deviceID }
                ContentUnavailableView {
                    Label(device?.state == "unauthorized"
                          ? String(localized: "Device unauthorized — accept the debugging prompt on the device")
                          : String(localized: "Android device not connected"), systemImage: "cable.connector.slash")
                } description: {
                    Text("Enable USB debugging on the Android device and connect it by USB, or use wireless debugging.")
                } actions: {
                    Button("Wireless Connection…") { app.sheet = .connect }
                    Button("Setup Guide…") { app.sheet = .setupGuide(.android) }
                }
            }
        case .iphone:
            ContentUnavailableView {
                Label(app.devices.iphoneToolsInstalled ? "iPhone not connected" : "iPhone access is not set up",
                      systemImage: "iphone.slash")
            } description: {
                Text(app.devices.iphoneToolsInstalled
                     ? String(localized: "Connect the iPhone by USB, unlock it and tap “Trust This Computer”. For Wi-Fi: after connecting by USB once, select the iPhone in Finder and turn on “Show this iPhone when on Wi-Fi”; it then appears here whenever it is on the same network.")
                     : String(localized: "iPhone access needs the free libimobiledevice tools."))
            } actions: {
                Button("Setup Guide…") { app.sheet = .setupGuide(.iphone) }
            }
        case .mtp:
            ContentUnavailableView {
                Label(MTP.isAvailable ? "MTP device not connected" : "MTP access is not set up",
                      systemImage: "cable.connector.slash")
            } description: {
                if MTP.isAvailable {
                    Text(app.devices.mtpErrors.first
                         ?? String(localized: "Connect the device by USB and choose “File transfer” (MTP) on it."))
                } else {
                    Text("MTP access needs the free libmtp library: brew install libmtp")
                }
            }
        default:
            EmptyView()
        }
    }

    private func chooseMacFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: model.path)
        if panel.runModal() == .OK, let url = panel.url { model.navigate(to: url.path) }
    }

    private var table: some View {
        @Bindable var model = model
        // 點欄位標題排序：轉成 model.sortType（與排序選單同一份狀態）
        let sortOrder = Binding<[FileColumnComparator]>(
            get: { FileColumnComparator(model.sortType).map { [$0] } ?? [] },
            set: { if let first = $0.first { model.sortType = first.sortType } }
        )
        return Table(of: FileItem.self, selection: $model.selection, sortOrder: sortOrder) {
            // 名稱欄不給 ideal，吸收剩餘寬度；其餘欄固定窄寬，窗格窄時不出現水平捲軸
            TableColumn("Name", sortUsing: FileColumnComparator(.name)) { FileNameCell(item: $0) }
                .width(min: 120)
            TableColumn("Size", sortUsing: FileColumnComparator(.size)) { Text($0.sizeText).monospacedDigit().foregroundStyle(.secondary) }
                .width(68)
            TableColumn("Modified", sortUsing: FileColumnComparator(.date)) { Text(FileDateFormat.string($0.modified)).monospacedDigit().foregroundStyle(.secondary) }
                .width(132)
            TableColumn("Permissions") {
                Text($0.permissions).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            .width(78)
        } rows: {
            ForEach(model.visibleFiles) { item in
                TableRow(item).itemProvider { app.dragProvider(for: item, in: side) }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            PaneContextMenu(app: app, side: side, items: model.files(for: ids))
        } primaryAction: { ids in
            if ids.count == 1, let item = model.files(for: ids).first { app.open(item, in: side) }
        }
        .onCopyCommand { app.pasteboardProviders(model.selectedFiles, from: side, move: false) }
        .onCutCommand { app.pasteboardProviders(model.selectedFiles, from: side, move: true) }
        .onPasteCommand(of: [.afmItems, .fileURL]) { _ in
            app.paste(into: side)
        }
        .onDeleteCommand {
            app.requestDelete(model.selectedFiles, in: side)
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(model.visibleFiles.count) items")
            if !model.selection.isEmpty { Text("· \(model.selection.count) selected") }
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// 窗格右鍵選單。對單一項目、多選項目或空白處（只有新增／貼上）都適用。
struct PaneContextMenu: View {
    let app: AppModel
    let side: PaneSide
    let items: [FileItem]

    private var model: BrowserModel { app.pane(side) }
    private var otherTitle: String { app.title(for: app.pane(side.other).sourceID) }

    var body: some View {
        if items.isEmpty {
            Button("New Folder…") { app.sheet = .newFolder(side) }
            Button("New File…") { app.sheet = .newFile(side) }
            Divider()
            Button("Paste") { app.paste(into: side) }
                .disabled(!app.canPaste)
            Button("Refresh") { model.reload() }
        } else {
            if items.count == 1, let item = items.first {
                Button(item.isDirectory ? "Open" : "Open / Edit") { app.open(item, in: side) }
                if !item.isDirectory {
                    if item.kind == .apk && (model.androidSource != nil || model.sourceID == .mac) {
                        Button("Install APK on Device") { app.pendingInstall = (side, item) }
                    }
                    Button("Open with Default App") { app.openWithDefaultApp(item, in: side) }
                    Button("Edit as Text") { app.edit(item, in: side) }
                }
                Divider()
            }
            Button("Copy") { app.copyToPasteboard(items, from: side, move: false) }
            Button("Cut") { app.copyToPasteboard(items, from: side, move: true) }
            if items.count == 1, let folder = items.first, folder.isDirectory {
                Button("Paste into “\(folder.name)”") { app.paste(into: side, directory: folder.path) }
                    .disabled(!app.canPaste)
            } else {
                Button("Paste") { app.paste(into: side) }
                    .disabled(!app.canPaste)
            }
            Divider()
            Button("Copy to Other Pane (\(otherTitle))") { app.sendToOtherPane(items, from: side, move: false) }
                .disabled(app.pane(side.other).source == nil)
            Button("Move to Other Pane (\(otherTitle))") { app.sendToOtherPane(items, from: side, move: true) }
                .disabled(app.pane(side.other).source == nil)
            if model.sourceID != .mac {
                Button("Export to Mac Folder…") { app.exportWithPanel(items, from: side) }
            }
            Divider()
            if items.count == 1, let item = items.first {
                Button("Rename…") { app.sheet = .rename(side, item) }
                if model.capabilities.permissions {
                    Button("Permissions…") { app.sheet = .permissions(side, item) }
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                }
                if model.sourceID == .mac {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                }
                Divider()
            }
            Button(model.capabilities.deleteMovesToTrash ? "Move to Trash" : "Delete…", role: .destructive) {
                app.requestDelete(items, in: side)
            }
        }
    }
}

/// 窗格的放下處理。
///
/// 窗格之間的拖曳（`.afmItems`）不載入任何拖曳資料，直接用 `AppModel.activeDrag` 完成：
/// 若像 `onDrop(of:isTargeted:perform:)` 那樣交出 item provider，系統會先要求「拖到 Finder 用」的
/// 檔案表示法（需整份下載），導致放下停住（藍框不消失、檔案沒動）。
/// 只有從 Finder 等外部拖入時，才讀取檔案網址。
struct PaneDropDelegate: DropDelegate {
    let app: AppModel
    let side: PaneSide
    let highlight: DropTargetState

    /// 拖放流程追蹤（`log stream --predicate 'subsystem == "idv.hassen.smartphonefilemanager" AND category == "drag"'`）
    static let log = Logger(subsystem: "idv.hassen.smartphonefilemanager", category: "drag")

    func dropEntered(info: DropInfo) {
        Self.log.notice("dropEntered \(side.rawValue, privacy: .public) afm=\(info.hasItemsConforming(to: [.afmItems])) activeDrag=\(app.activeDrag?.items.count ?? -1)")
        highlight.set(true)
    }
    func dropExited(info: DropInfo) {
        Self.log.notice("dropExited \(side.rawValue, privacy: .public)")
        highlight.set(false)
    }
    func validateDrop(info: DropInfo) -> Bool {
        Self.log.notice("validateDrop \(side.rawValue, privacy: .public)")
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [.afmItems])
                     ? app.dropOperation(on: side, optionHeld: NSEvent.modifierFlags.contains(.option))
                     : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        Self.log.notice("performDrop \(side.rawValue, privacy: .public) afm=\(info.hasItemsConforming(to: [.afmItems])) activeDrag=\(app.activeDrag?.items.count ?? -1)")
        highlight.set(false)
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        if info.hasItemsConforming(to: [.afmItems]),
           app.handleInternalDrop(on: side, optionHeld: optionHeld) {
            return true
        }
        return app.handleDrop(info.itemProviders(for: [.afmItems, .fileURL]), on: side)
    }
}
