import AFMCore
import SwiftUI
import UniformTypeIdentifiers

/// 裝置端窗格（右側）
struct RemotePaneView: View {
    @Bindable var app: AppModel
    @State private var dropTargeted = false

    private var model: RemoteBrowserModel { app.remote }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(DropHighlight(active: dropTargeted))
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { app.handleRemoteDrop($0) }
            Divider()
            statusBar
        }
        // HSplitView 不會自動把子視圖撐滿高度，必須明確給 maxHeight
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 標題列

    private var header: some View {
        @Bindable var model = model
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "iphone").foregroundStyle(.secondary)
                Text(app.devices.selectedDevice?.displayName ?? String(localized: "No device"))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                TextField("Filter", text: $model.filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
            }
            HStack(spacing: 4) {
                Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                    .help("Parent Folder")
                    .disabled(model.path == "/")
                Button { model.navigate(to: RemoteBrowserModel.homePath) } label: { Image(systemName: "house") }
                    .help("Internal Storage (/sdcard)")
                PathBar(components: pathComponents, onSelect: { model.navigate(to: $0) },
                        onSubmit: { model.go(toTyped: $0) }, fullPath: model.path)
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .keyboardShortcut("r", modifiers: .command)
                newMenu
                bookmarkMenu
                SortMenu(sortType: $model.sortType)
                Button { app.sheet = .search } label: { Image(systemName: "magnifyingglass") }
                    .help("Search Subfolders")
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            .buttonStyle(.borderless)
            .disabled(app.devices.connection == nil)
        }
        .padding(8)
    }

    private var pathComponents: [(title: String, target: String)] {
        var result: [(String, String)] = [("/", "/")]
        var current = ""
        for part in RemotePath.components(model.path) {
            current += "/" + part
            result.append((part, current))
        }
        return result
    }

    private var newMenu: some View {
        Menu {
            Button("New Folder…") { app.sheet = .newFolder }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New File…") { app.sheet = .newFile }
        } label: {
            Image(systemName: "plus")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New")
    }

    private var bookmarkMenu: some View {
        Menu {
            if app.bookmarks.contains(path: model.path) {
                Button("Remove Bookmark for This Folder") {
                    if let bookmark = app.bookmarks.bookmarks.first(where: { $0.path == model.path }) {
                        try? app.bookmarks.remove(bookmark)
                    }
                }
            } else {
                Button("Bookmark This Folder…") { app.sheet = .addBookmark }
                    .keyboardShortcut("d", modifiers: .command)
            }
            if !app.bookmarks.bookmarks.isEmpty {
                Divider()
                ForEach(app.bookmarks.bookmarks) { bookmark in
                    Menu(bookmark.name) {
                        Button("Open \(bookmark.path)") { model.navigate(to: bookmark.path) }
                        Button("Delete Bookmark", role: .destructive) { try? app.bookmarks.remove(bookmark) }
                    } primaryAction: {
                        model.navigate(to: bookmark.path)
                    }
                }
            }
        } label: {
            Image(systemName: app.bookmarks.contains(path: model.path) ? "bookmark.fill" : "bookmark")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bookmarks")
    }

    // MARK: 內容

    @ViewBuilder
    private var content: some View {
        if let error = app.devices.adbError {
            ContentUnavailableView {
                Label("ADB is not available", systemImage: "wrench.and.screwdriver")
            } description: {
                Text(error)
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        } else {
            switch model.phase {
            case .noDevice:
                ContentUnavailableView {
                    Label(noDeviceTitle, systemImage: "cable.connector.slash")
                } description: {
                    Text("Enable USB debugging on the Android device and connect it by USB, or use wireless debugging.")
                } actions: {
                    Button("Wireless Connection…") { app.sheet = .connect }
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("Cannot open folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Go to Parent Folder") { model.goUp() }
                    Button("Retry") { model.reload() }
                }
            case .loading, .loaded:
                table
                    .overlay {
                        if model.phase == .loading { ProgressView() }
                        else if model.visibleFiles.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
                    }
            }
        }
    }

    private var noDeviceTitle: String {
        if let device = app.devices.selectedDevice, !device.isReady {
            return device.state == "unauthorized"
                ? String(localized: "Device unauthorized — accept the debugging prompt on the device")
                : String(localized: "Device is \(device.state)")
        }
        return String(localized: "No device connected")
    }

    private var table: some View {
        @Bindable var model = model
        return Table(of: RemoteFile.self, selection: $model.selection) {
            // 名稱欄不給 ideal，吸收剩餘寬度；其餘欄固定窄寬，窗格窄時不出現水平捲軸
            TableColumn("Name") { FileNameCell(entry: $0) }
                .width(min: 120)
            TableColumn("Size") { Text($0.sizeText).monospacedDigit().foregroundStyle(.secondary) }
                .width(68)
            TableColumn("Modified") { Text(FileDateFormat.string($0.modified)).monospacedDigit().foregroundStyle(.secondary) }
                .width(132)
            TableColumn("Permissions") {
                Text($0.permissions).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            .width(78)
        } rows: {
            ForEach(model.visibleFiles) { file in
                TableRow(file).itemProvider { app.dragProvider(for: file) }
            }
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            RemoteContextMenu(app: app, files: model.files(for: ids))
        } primaryAction: { ids in
            if ids.count == 1, let file = model.files(for: ids).first { app.openRemote(file) }
        }
        .onDeleteCommand {
            if !model.selectedFiles.isEmpty { app.pendingDeletion = model.selectedFiles }
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

/// 裝置端右鍵選單；對多選項目批次操作
struct RemoteContextMenu: View {
    let app: AppModel
    let files: [RemoteFile]

    var body: some View {
        if files.isEmpty {
            Button("New Folder…") { app.sheet = .newFolder }
            Button("New File…") { app.sheet = .newFile }
            Button("Refresh") { app.remote.reload() }
        } else {
            if files.count == 1, let file = files.first {
                Button(file.isDirectory ? "Open" : "Open / Edit") { app.openRemote(file) }
                if !file.isDirectory {
                    if file.kind == .apk { Button("Install APK") { app.pendingInstall = file } }
                    Button("Open with Default App") { app.openWithDefaultApp(file) }
                    Button("Edit as Text") { app.edit(file) }
                }
                Divider()
            }
            Button("Copy to Mac Folder “\(app.local.directory.lastPathComponent)”") {
                app.download(files, to: app.local.directory)
            }
            .disabled(!app.local.isWritable)
            Button("Export to…") { app.exportWithPanel(files) }
            Button("Move to…  (export, then delete from device)") { app.exportWithPanel(files, deleteAfter: true) }
            Divider()
            Button("Copy on Device…") { app.sheet = .copyMove(files, move: false) }
            Button("Move on Device…") { app.sheet = .copyMove(files, move: true) }
            if files.count == 1, let file = files.first {
                Button("Rename…") { app.sheet = .rename(file) }
                Button("Permissions…") { app.sheet = .permissions(file) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { app.pendingDeletion = files }
        }
    }
}
