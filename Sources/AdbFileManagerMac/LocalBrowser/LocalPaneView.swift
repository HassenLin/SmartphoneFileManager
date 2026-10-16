import AFMCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 本機窗格（左側，可收合）
struct LocalPaneView: View {
    @Bindable var app: AppModel
    @State private var dropTargeted = false

    private var model: LocalBrowserModel { app.local }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(DropHighlight(active: dropTargeted))
                .onDrop(of: [.fileURL, .remoteFile], isTargeted: $dropTargeted) { app.handleLocalDrop($0) }
            Divider()
            statusBar
        }
        // HSplitView 不會自動把子視圖撐滿高度，必須明確給 maxHeight
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.reload() }
    }

    private var header: some View {
        @Bindable var model = model
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                Text("This Mac").font(.headline)
                Spacer()
                if !model.isWritable {
                    Label("Read-only", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .help("Copying from the device is disabled for read-only folders.")
                }
            }
            HStack(spacing: 4) {
                Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                    .help("Parent Folder")
                placesMenu
                PathBar(components: pathComponents, onSelect: { model.navigate(to: URL(fileURLWithPath: $0)) },
                        onSubmit: { typed in
                            let path = (typed as NSString).expandingTildeInPath
                            var isDirectory: ObjCBool = false
                            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                                model.navigate(to: URL(fileURLWithPath: path))
                            } else {
                                app.toasts.error(String(localized: "Folder not found: \(path)"))
                            }
                        },
                        fullPath: model.directory.path)
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button { model.revealInFinder(model.selectedFiles.map(\.url)) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                SortMenu(sortType: $model.sortType)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
    }

    private var pathComponents: [(title: String, target: String)] {
        var result: [(String, String)] = []
        var url = model.directory
        while true {
            result.insert((url.path == "/" ? "/" : url.lastPathComponent, url.path), at: 0)
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return result
    }

    private var placesMenu: some View {
        Menu {
            ForEach(places, id: \.1) { title, url in
                Button(title) { model.navigate(to: url) }
            }
            Divider()
            Button("Choose Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = model.directory
                if panel.runModal() == .OK, let url = panel.url { model.navigate(to: url) }
            }
        } label: {
            Image(systemName: "sidebar.squares.left")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Places")
    }

    private var places: [(String, URL)] {
        let fm = FileManager.default
        var list: [(String, URL)] = [(String(localized: "Home"), fm.homeDirectoryForCurrentUser)]
        for (title, directory) in [(String(localized: "Desktop"), FileManager.SearchPathDirectory.desktopDirectory),
                                   (String(localized: "Documents"), .documentDirectory),
                                   (String(localized: "Downloads"), .downloadsDirectory)] {
            if let url = fm.urls(for: directory, in: .userDomainMask).first { list.append((title, url)) }
        }
        return list
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            ContentUnavailableView("Cannot open folder", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            table.overlay {
                if model.files.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
            }
        }
    }

    private var table: some View {
        @Bindable var model = model
        return Table(of: LocalFile.self, selection: $model.selection) {
            TableColumn("Name") { FileNameCell(entry: $0) }
                .width(min: 160, ideal: 240)
            TableColumn("Size") { Text($0.sizeText).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80, max: 110)
            TableColumn("Modified") { Text(FileDateFormat.string($0.modified)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 110, ideal: 130, max: 160)
        } rows: {
            ForEach(model.files) { file in
                TableRow(file).itemProvider { NSItemProvider(contentsOf: file.url) }
            }
        }
        .contextMenu(forSelectionType: LocalFile.ID.self) { ids in
            let files = model.files(for: ids)
            if !files.isEmpty {
                Button("Copy to Device Folder “\(RemotePath.name(of: app.remote.path))”") { app.upload(files.map(\.url)) }
                    .disabled(app.devices.connection == nil)
                if files.count == 1, let file = files.first, file.kind == .apk {
                    Button("Install APK on Device") { app.installLocalApk(file.url) }
                        .disabled(app.devices.connection == nil)
                }
                Divider()
                Button("Open") { files.forEach(model.open) }
                Button("Show in Finder") { model.revealInFinder(files.map(\.url)) }
            }
        } primaryAction: { ids in
            model.files(for: ids).first.map(model.open)
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(model.files.count) items")
            if !model.selection.isEmpty { Text("· \(model.selection.count) selected") }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
