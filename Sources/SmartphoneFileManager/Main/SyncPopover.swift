import SFMCore
import SwiftUI

/// 工具列「同步」按鈕：彈出 `SyncPopover`。顯示狀態放在 `AppModel`，書籤選單選了同步專案時也能打開它。
struct SyncToolbarButton: View {
    @Bindable var app: AppModel

    var body: some View {
        Button { app.isSyncPopoverPresented.toggle() } label: {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath").labelStyle(.titleAndIcon)
        }
        .help("Sync the two panes' folders (like rsync)")
        .popover(isPresented: $app.isSyncPopoverPresented, arrowEdge: .bottom) {
            SyncPopover(app: app)
        }
        .onChange(of: app.isSyncPopoverPresented) { _, shown in if !shown { app.syncProjectToEdit = nil } }
    }
}

/// 同步專案設定：專案名稱、方向、選項；取消／儲存／同步。
///
/// 開啟時決定要編輯的專案（`initialProject`）：書籤選單指定的專案 → 左右資料夾相同的既有專案 → 新專案。
/// 「儲存」寫入書籤庫；「同步」若與已儲存的內容不同（含新專案）先儲存，再加入工作佇列。
struct SyncPopover: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    /// 編輯中的專案；nil＝左右窗格還沒有來源，無法同步
    @State private var draft: SyncProject?
    /// 排除樣式的輸入文字（逗號分隔）。不直接雙向綁定陣列：那樣打到一半的逗號會被正規化吃掉
    @State private var excludeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync").font(.headline)
            if let binding = Binding($draft) {
                form(binding)
            } else {
                Text("Choose a source and folder in both panes first.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear {
            draft = initialProject()
            excludeText = draft?.options.excludePatterns.joined(separator: ", ") ?? ""
        }
        .onChange(of: excludeText) { _, text in
            draft?.options.excludePatterns = text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    private func initialProject() -> SyncProject? {
        if let project = app.bookmarks.syncProject(app.syncProjectToEdit) { return project }
        guard let left = app.location(of: .left), let right = app.location(of: .right) else { return nil }
        if let project = app.bookmarks.syncProject(left: left, right: right) { return project }
        let name = "\(RemotePath.name(of: left.path)) ⇄ \(RemotePath.name(of: right.path))"
        return SyncProject(name: name, left: left, right: right)
    }

    private func form(_ project: Binding<SyncProject>) -> some View {
        let isSaved = app.bookmarks.syncProject(project.wrappedValue.id) == project.wrappedValue
        let isNew = app.bookmarks.syncProject(project.wrappedValue.id) == nil
        return VStack(alignment: .leading, spacing: 12) {
            TextField("Project name", text: project.name).textFieldStyle(.roundedBorder)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                locationRow("Left", project.wrappedValue.left)
                locationRow("Right", project.wrappedValue.right)
            }
            Picker("Direction", selection: project.direction) {
                Text("Left → Right").tag(SyncDirection.leftToRight)
                Text("Left ← Right").tag(SyncDirection.rightToLeft)
                Text("Left ↔ Right").tag(SyncDirection.twoWay)
            }
            .pickerStyle(.segmented)
            options(project)
            HStack {
                if isNew { Text("New project").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if save(project.wrappedValue) { dismiss() }
                }
                .disabled(isSaved || project.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Sync") {
                    let current = project.wrappedValue
                    if !isSaved, !save(current) { return }
                    app.runSync(current)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(project.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// 選項依來源組合的能力顯示：通用選項一律顯示；兩邊都是 Mac 時多出 rsync 專用選項
    @ViewBuilder
    private func options(_ project: Binding<SyncProject>) -> some View {
        let capabilities = SyncCapabilities(from: project.wrappedValue.from.source, to: project.wrappedValue.to.source)
        let options = project.options
        VStack(alignment: .leading, spacing: 6) {
            let twoWay = project.wrappedValue.direction == .twoWay
            Toggle("Delete items in the destination that are not in the source", isOn: options.deleteExtraneous)
                .disabled(twoWay)
            if twoWay {
                Text("Two-way: the newer file wins on each side; nothing is deleted (without a record of the last sync, a deletion looks the same as a new file on the other side).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Include hidden files", isOn: options.includeHidden)
            Toggle("Compare size only (ignore modification time)", isOn: options.sizeOnly)
            Toggle("Skip files that already exist in the destination", isOn: options.ignoreExisting)
            TextField("Exclude (comma separated, e.g. *.tmp, node_modules)", text: $excludeText)
                .textFieldStyle(.roundedBorder)
        }
        if capabilities.usesRsync {
            GroupBox("rsync (Mac ↔ Mac)") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Compare by checksum (slow, exact)", isOn: options.checksum)
                    Toggle("Preserve extended attributes", isOn: options.extendedAttributes)
                    TextField("Additional rsync arguments", text: options.extraArguments)
                        .textFieldStyle(.roundedBorder)
                    Text("Always runs rsync -a (keeps times, permissions and links).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Copies new files and files whose size differs or that are newer in the source. Files on the Mac are moved to the Trash when deleted. Checksum and other rsync options are only available when both folders are on this Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save(_ project: SyncProject) -> Bool {
        do {
            try app.bookmarks.saveSyncProject(project)
            return true
        } catch {
            app.toasts.error(error)
            return false
        }
    }

    private func locationRow(_ title: LocalizedStringKey, _ location: FolderLocation) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Label {
                Text("\(app.title(for: location.source)): \(location.path)")
                    .lineLimit(1).truncationMode(.middle).help(location.path)
            } icon: {
                Image(systemName: app.symbol(for: location.source))
            }
        }
    }
}
