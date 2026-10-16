import SFMCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主視窗目前顯示的面板。同一時間只有一個（SwiftUI `.sheet(item:)` 的限制）。
/// 與窗格有關的面板帶著 `PaneSide`，確認後作用在對的窗格。
enum ActiveSheet: Identifiable {
    case newFolder(PaneSide)
    case newFile(PaneSide)
    case rename(PaneSide, FileItem)
    case permissions(PaneSide, FileItem)
    case addBookmark(PaneSide)
    case search(PaneSide)
    case clipboard
    case connect
    case deviceInfo
    case appManager
    case imagePreview(ImagePreviewModel)
    case editor(EditorModel)

    var id: String {
        switch self {
        case let .newFolder(side): return "newFolder:\(side)"
        case let .newFile(side): return "newFile:\(side)"
        case let .rename(side, item): return "rename:\(side):\(item.path)"
        case let .permissions(side, item): return "permissions:\(side):\(item.path)"
        case let .addBookmark(side): return "addBookmark:\(side)"
        case let .search(side): return "search:\(side)"
        case .clipboard: return "clipboard"
        case .connect: return "connect"
        case .deviceInfo: return "deviceInfo"
        case .appManager: return "appManager"
        case let .imagePreview(model): return "image:\(model.item.path)"
        case let .editor(model): return "editor:\(model.item.path)"
        }
    }
}

/// 剪貼簿／拖曳攜帶的內容：哪個來源的哪些項目，以及是否為「剪下」
struct FilePayload: Codable {
    let source: SourceID
    let items: [FileItem]
    let move: Bool
}

extension UTType {
    /// 宣告於 Info.plist 的 UTExportedTypeDeclarations（make-app.sh 產生）
    static let afmItems = UTType(exportedAs: "idv.hassen.smartphonefilemanager.remote-file", conformingTo: .data)
}

/// 刪除確認（哪個窗格的哪些項目）
struct PendingDeletion {
    let side: PaneSide
    let items: [FileItem]
    let toTrash: Bool
}

/// App 層協調者：持有各子模型，負責跨窗格／跨來源的動作（剪貼簿、傳輸、拖放、開啟檔案）。
///
/// 依賴方向：View → AppModel → BrowserModel／DeviceMonitor → SFMCore（FileSource、FileTransfer）。
/// 兩個 BrowserModel 互不參考；需要兩邊資訊的動作都集中在這裡。
@MainActor
@Observable
final class AppModel {
    let toasts = ToastCenter()
    let transfers = TransferCenter()
    let bookmarks = BookmarkStore()
    let devices = DeviceMonitor()
    let terminals = TerminalStore()
    let left: BrowserModel
    let right: BrowserModel

    var sheet: ActiveSheet?
    var pendingDeletion: PendingDeletion?
    var pendingInstall: (side: PaneSide, item: FileItem)?
    /// app 內剪貼簿（剪下／拷貝後尚未貼上的項目），狀態列顯示用；實際貼上以系統剪貼簿內容為準
    private(set) var clipboard: FilePayload?
    var isLeftPaneCollapsed: Bool {
        didSet { UserDefaults.standard.set(isLeftPaneCollapsed, forKey: SettingsKey.localPaneCollapsed) }
    }

    @ObservationIgnored private var didAutoSelectRight = false

    init() {
        left = BrowserModel(side: .left, sourceID: Self.savedSource(.left) ?? .mac, toasts: toasts)
        right = BrowserModel(side: .right, sourceID: Self.savedSource(.right), toasts: toasts)
        isLeftPaneCollapsed = UserDefaults.standard.bool(forKey: SettingsKey.localPaneCollapsed)
    }

    func pane(_ side: PaneSide) -> BrowserModel { side == .left ? left : right }

    func start() {
        devices.start()
        refreshSources()
    }

    // MARK: 來源

    /// 窗格來源選單的項目
    struct SourceOption: Identifiable {
        let id: SourceID
        let title: String
        let symbol: String
        let enabled: Bool
    }

    var sourceOptions: [SourceOption] {
        var options = [SourceOption(id: .mac, title: String(localized: "This Mac"), symbol: "laptopcomputer", enabled: true)]
        for device in devices.devices {
            options.append(SourceOption(id: .android(device.serial),
                                        title: device.isReady ? device.displayName : "\(device.displayName) — \(device.state)",
                                        symbol: "candybarphone", enabled: device.isReady))
        }
        for phone in devices.iphones {
            options.append(SourceOption(id: .iphone(phone.udid), title: phone.name, symbol: "iphone", enabled: true))
        }
        return options
    }

    func title(for id: SourceID?) -> String {
        guard let id else { return String(localized: "Choose a source") }
        if let option = sourceOptions.first(where: { $0.id == id }) { return option.title }
        switch id.kind {
        case .mac: return String(localized: "This Mac")
        case .android: return String(localized: "Android \(id.deviceID) (disconnected)")
        case .iphone: return String(localized: "iPhone (disconnected)")
        }
    }

    func symbol(for id: SourceID?) -> String {
        switch id?.kind {
        case .mac: return "laptopcomputer"
        case .android: return "candybarphone"
        case .iphone: return "iphone"
        case nil: return "questionmark.folder"
        }
    }

    /// 把 SourceID 解析成可用的來源；裝置未連線／未授權／工具未安裝時為 nil
    func resolve(_ id: SourceID?) -> (any FileSource)? {
        guard let id else { return nil }
        switch id.kind {
        case .mac:
            return MacFileSource()
        case .android:
            guard devices.devices.contains(where: { $0.serial == id.deviceID && $0.isReady }) else { return nil }
            return AndroidFileSource(device: AdbClient.current.device(id.deviceID))
        case .iphone:
            guard devices.iphones.contains(where: { $0.udid == id.deviceID }),
                  let tool = IPhoneFileSource.locateTool() else { return nil }
            return IPhoneFileSource(udid: id.deviceID, executable: tool)
        }
    }

    func selectSource(_ id: SourceID, for side: PaneSide) {
        pane(side).select(id, resolved: resolve(id))
        if let data = try? JSONEncoder().encode(id) {
            UserDefaults.standard.set(data, forKey: "paneSource.\(side.rawValue)")
        }
    }

    private static func savedSource(_ side: PaneSide) -> SourceID? {
        guard let data = UserDefaults.standard.data(forKey: "paneSource.\(side.rawValue)") else { return nil }
        return try? JSONDecoder().decode(SourceID.self, from: data)
    }

    /// 裝置清單變動時呼叫：更新兩窗格的來源可用性；右窗格尚未選擇時自動選第一台裝置
    func refreshSources() {
        if right.sourceID == nil, !didAutoSelectRight,
           let first = sourceOptions.first(where: { $0.id != .mac && $0.enabled }) {
            didAutoSelectRight = true
            selectSource(first.id, for: .right)
        }
        left.updateResolved(resolve(left.sourceID))
        right.updateResolved(resolve(right.sourceID))
    }

    /// 某來源內容變了：所有顯示該來源的窗格都重新載入
    func reloadPanes(showing id: SourceID, highlight: [String] = []) {
        for pane in [left, right] where pane.sourceID == id {
            pane.pendingHighlight = Set(highlight)
            pane.reload()
        }
    }

    // MARK: 剪貼簿（拷貝／剪下／貼上）

    /// 寫入系統剪貼簿：自有型別（含來源與是否剪下）＋ Mac 項目的檔案 URL（可直接貼到 Finder）
    func copyToPasteboard(_ items: [FileItem], from side: PaneSide, move: Bool) {
        guard !items.isEmpty, let sourceID = pane(side).sourceID else { return }
        let payload = FilePayload(source: sourceID, items: items, move: move)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let pasteboardItem = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(payload) {
            pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(UTType.afmItems.identifier))
        }
        pasteboardItem.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
        var objects: [NSPasteboardWriting] = [pasteboardItem]
        if sourceID == .mac && !move {
            objects += items.map { URL(fileURLWithPath: $0.path) as NSURL }
        }
        pasteboard.writeObjects(objects)
        clipboard = payload
        toasts.success(move
            ? String(localized: "Cut \(items.count) item(s) — paste to move")
            : String(localized: "Copied \(items.count) item(s) — paste to copy"))
    }

    /// ⌘C／⌘X（表格焦點）：交給 SwiftUI 寫入系統剪貼簿的 item provider
    func pasteboardProviders(_ items: [FileItem], from side: PaneSide, move: Bool) -> [NSItemProvider] {
        guard !items.isEmpty, let sourceID = pane(side).sourceID,
              let data = try? JSONEncoder().encode(FilePayload(source: sourceID, items: items, move: move)) else { return [] }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.afmItems.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        var providers = [provider]
        if sourceID == .mac && !move {
            providers += items.compactMap { NSItemProvider(contentsOf: URL(fileURLWithPath: $0.path)) }
        }
        clipboard = FilePayload(source: sourceID, items: items, move: move)
        toasts.success(move
            ? String(localized: "Cut \(items.count) item(s) — paste to move")
            : String(localized: "Copied \(items.count) item(s) — paste to copy"))
        return providers
    }

    /// 從系統剪貼簿讀出可貼上的內容：本 app 拷貝的項目，或 Finder 拷貝的檔案
    func pasteboardPayload() -> FilePayload? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.afmItems.identifier)),
           let payload = try? JSONDecoder().decode(FilePayload.self, from: data) {
            return payload
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return nil }
        return FilePayload(source: .mac, items: urls.map(Self.macItem), move: false)
    }

    var canPaste: Bool { pasteboardPayload() != nil }

    /// 貼上到窗格目前資料夾（或指定資料夾）
    func paste(into side: PaneSide, directory: String? = nil) {
        guard let payload = pasteboardPayload() else { return }
        transfer(payload.items, from: payload.source, to: side, directory: directory, move: payload.move) { [self] in
            // 剪下的項目貼上後即失效（與 Finder 相同）
            if payload.move {
                NSPasteboard.general.clearContents()
                clipboard = nil
            }
        }
    }

    // MARK: 傳輸

    /// 任意來源 → 某窗格的資料夾。實際路徑選擇（原生／經 Mac 中繼）見 `FileTransfer`。
    func transfer(_ items: [FileItem], from sourceID: SourceID, to side: PaneSide, directory: String? = nil,
                  move: Bool, completion: @escaping @MainActor () -> Void = {}) {
        let destinationPane = pane(side)
        guard !items.isEmpty else { return }
        guard let source = resolve(sourceID) else {
            return toasts.error(String(localized: "The source device is not connected"))
        }
        guard let destination = destinationPane.source, let destinationID = destinationPane.sourceID else {
            return toasts.error(String(localized: "The destination is not available"))
        }
        let directory = directory ?? destinationPane.path
        let title = move ? String(localized: "Moving") : String(localized: "Copying")

        transfers.start(title: "\(title) → \(self.title(for: destinationID))") { center in
            let result = try await FileTransfer.run(items: items, from: source, to: destination,
                                                    directory: directory, move: move, report: center.transferSink())
            await MainActor.run {
                self.finishTransfer(result, sourceID: sourceID, destinationID: destinationID, move: move)
            }
        } completion: { [self] error in
            if let error {
                if error is CancellationError { toasts.success(String(localized: "Transfer cancelled")) } else { toasts.error(error) }
                reloadPanes(showing: destinationID)
                if move { reloadPanes(showing: sourceID) }
            }
            completion()
        }
    }

    private func finishTransfer(_ result: FileTransfer.Result, sourceID: SourceID, destinationID: SourceID, move: Bool) {
        if result.failures.isEmpty {
            if !result.completed.isEmpty {
                toasts.success(move ? String(localized: "Moved \(result.completed.count) item(s)")
                                    : String(localized: "Copied \(result.completed.count) item(s)"))
            }
        } else {
            let detail = result.failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")
            toasts.error(String(localized: "\(result.completed.count) succeeded, failed: \(detail)"))
        }
        if move { reloadPanes(showing: sourceID) }
        reloadPanes(showing: destinationID, highlight: result.completed)
    }

    /// 「複製／移動到另一窗格」
    func sendToOtherPane(_ items: [FileItem], from side: PaneSide, move: Bool) {
        guard let sourceID = pane(side).sourceID else { return }
        transfer(items, from: sourceID, to: side.other, move: move)
    }

    /// 把非 Mac 項目匯出到選擇的 Mac 資料夾
    func exportWithPanel(_ items: [FileItem], from side: PaneSide) {
        guard let sourceID = pane(side).sourceID else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        guard panel.runModal() == .OK, let url = panel.url,
              let source = resolve(sourceID) else { return }
        transfers.start(title: String(localized: "Copying to Mac")) { center in
            let result = try await FileTransfer.run(items: items, from: source, to: MacFileSource(),
                                                    directory: url.path, move: false, report: center.transferSink())
            await MainActor.run { self.finishTransfer(result, sourceID: sourceID, destinationID: .mac, move: false) }
        } completion: { [toasts] error in
            if let error, !(error is CancellationError) { toasts.error(error) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: 刪除

    func requestDelete(_ items: [FileItem], in side: PaneSide) {
        guard !items.isEmpty else { return }
        pendingDeletion = PendingDeletion(side: side, items: items,
                                          toTrash: pane(side).capabilities.deleteMovesToTrash)
    }

    func confirmDelete() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        pane(pending.side).delete(pending.items)
        // 另一窗格若顯示同一來源，也一併更新
        let other = pane(pending.side.other)
        if other.sourceID == pane(pending.side).sourceID {
            Task { try? await Task.sleep(for: .milliseconds(600)); other.reload() }
        }
    }

    // MARK: 開啟

    /// 雙擊／Return：資料夾進入、文字檔編輯、圖片預覽、APK 詢問安裝、其他以預設 App 開啟
    func open(_ item: FileItem, in side: PaneSide) {
        let browser = pane(side)
        if item.isDirectory { return browser.navigate(to: item.path) }
        if browser.sourceID == .mac && !item.kind.isEditableText {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            return
        }
        switch item.kind {
        case .image: previewImage(item, in: side)
        case .apk where browser.androidSource != nil || browser.sourceID == .mac: pendingInstall = (side, item)
        default:
            if item.kind.isEditableText || (item.size < 64 * 1024 && item.kind == .other) {
                edit(item, in: side)
            } else {
                openWithDefaultApp(item, in: side)
            }
        }
    }

    func edit(_ item: FileItem, in side: PaneSide) {
        guard let source = pane(side).source else { return toasts.error(AdbError.noDevice) }
        let editor = EditorModel(item: item, source: source, toasts: toasts)
        sheet = .editor(editor)
        editor.load()
    }

    func previewImage(_ item: FileItem, in side: PaneSide) {
        guard let source = pane(side).source else { return toasts.error(AdbError.noDevice) }
        let preview = ImagePreviewModel(item: item)
        sheet = .imagePreview(preview)
        preview.load(from: source)
    }

    /// 下載到暫存資料夾後交給 macOS 預設 App（Mac 項目直接開）
    func openWithDefaultApp(_ item: FileItem, in side: PaneSide) {
        guard let source = pane(side).source else { return toasts.error(AdbError.noDevice) }
        if source.id == .mac { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afm-open-\(UUID().uuidString)")
        let local = directory.appendingPathComponent(item.name)
        transfers.start(title: String(localized: "Opening")) { center in
            center.begin(item: item.name, index: 0, count: 1)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await source.download(item.path, to: local, expectedSize: item.size, onProgress: center.progressSink())
        } completion: { [toasts] error in
            if let error { return toasts.error(error) }
            NSWorkspace.shared.open(local)
        }
    }

    /// 安裝 APK：Android 窗格用 `pm install`；Mac 窗格用 `adb install` 裝到工具列選取的裝置
    func install(_ item: FileItem, in side: PaneSide) {
        let browser = pane(side)
        if browser.androidSource != nil { return browser.installApk(item) }
        guard browser.sourceID == .mac else { return }
        guard let connection = devices.connection else { return toasts.error(AdbError.noDevice) }
        transfers.start(title: String(localized: "Installing APK")) { center in
            center.begin(item: item.name, index: 0, count: 1)
            _ = try await connection.install(localApk: item.path)
        } completion: { [toasts] error in
            if let error { toasts.error(error) } else { toasts.success(String(localized: "APK installed")) }
        }
    }

    // MARK: 拖放

    /// 列的拖曳來源：
    /// 1. 自有型別（拖到另一個窗格 → 走 FileTransfer，有進度可取消）
    /// 2. Mac 項目：檔案 URL（可拖到 Finder／其他 App）
    /// 3. 裝置項目：檔案承諾（拖到 Finder 時才下載到暫存資料夾再交出）
    func dragProvider(for item: FileItem, in side: PaneSide) -> NSItemProvider {
        let browser = pane(side)
        let provider = browser.sourceID == .mac
            ? (NSItemProvider(contentsOf: URL(fileURLWithPath: item.path)) ?? NSItemProvider())
            : NSItemProvider()
        if let sourceID = browser.sourceID,
           let data = try? JSONEncoder().encode(FilePayload(source: sourceID, items: [item], move: false)) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.afmItems.identifier, visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
        }
        if browser.sourceID != .mac, let source = browser.source {
            provider.suggestedName = item.name
            let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afm-drag-\(UUID().uuidString)")
                let destination = directory.appendingPathComponent(item.name)
                Task {
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try await source.download(item.path, to: destination, expectedSize: nil) { _ in }
                        completion(destination, false, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                return nil
            }
        }
        return provider
    }

    /// 放下到窗格：自有項目 → FileTransfer（拷貝）；Finder 檔案 → 從 Mac 拷貝。
    /// 拖回自己所在的同一資料夾視為不動作，避免誤觸產生副本。
    func handleDrop(_ providers: [NSItemProvider], on side: PaneSide, directory: String? = nil) -> Bool {
        let browser = pane(side)
        guard browser.source != nil else { return false }
        let target = directory ?? browser.path
        Task {
            var payloads: [FilePayload] = []
            var urls: [URL] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.afmItems.identifier) {
                    if let data = await provider.loadData(UTType.afmItems.identifier),
                       let payload = try? JSONDecoder().decode(FilePayload.self, from: data) {
                        payloads.append(payload)
                    }
                } else if let url = await provider.loadFileURL() {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                payloads.append(FilePayload(source: .mac, items: urls.map(Self.macItem), move: false))
            }
            // 依來源分組，各自一次傳輸
            for (sourceID, group) in Dictionary(grouping: payloads, by: \.source) {
                let items = group.flatMap(\.items).filter {
                    !(sourceID == browser.sourceID && RemotePath.parent(of: $0.path) == RemotePath.normalize(target))
                }
                transfer(items, from: sourceID, to: side, directory: target, move: false)
            }
        }
        return true
    }

    static func macItem(_ url: URL) -> FileItem {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return FileItem(path: url.path, isDirectory: isDirectory.boolValue, size: size)
    }

    // MARK: 裝置工具（工具列選取的 Android 裝置）

    func takeScreenshot() {
        guard let connection = devices.connection else { return toasts.error(AdbError.noDevice) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = downloads.appendingPathComponent("screenshot_\(formatter.string(from: Date())).png")
        Task {
            do {
                try await DeviceInfoService(device: connection).screenshot(to: destination)
                toasts.success(String(localized: "Screenshot saved: \(destination.lastPathComponent)"))
                reloadPanes(showing: .mac, highlight: [destination.path])
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                toasts.error(error)
            }
        }
    }

    func startScreenMirror() {
        guard let device = devices.selectedDevice, device.isReady else { return toasts.error(AdbError.noDevice) }
        guard let scrcpy = ScrcpyLauncher.locate() else {
            return toasts.error(String(localized: "scrcpy not found. Install it with “brew install scrcpy” or set its path in Settings."))
        }
        do {
            try ScrcpyLauncher.launch(executable: scrcpy, serial: device.serial,
                                      adbPath: AdbClient.current.executable, options: .fromDefaults())
        } catch {
            toasts.error(error)
        }
    }

    func reboot(_ mode: RebootMode) {
        guard let connection = devices.connection else { return toasts.error(AdbError.noDevice) }
        Task {
            do {
                try await DeviceInfoService(device: connection).reboot(mode)
                toasts.success(String(localized: "Reboot command sent"))
            } catch {
                toasts.error(error)
            }
        }
    }

    func openTerminal() -> Bool {
        guard let device = devices.selectedDevice, device.isReady else {
            toasts.error(AdbError.noDevice)
            return false
        }
        terminals.open(adbPath: AdbClient.current.executable, serial: device.serial)
        return true
    }
}

// MARK: - NSItemProvider async 輔助

extension NSItemProvider {
    @MainActor
    func loadData(_ typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    @MainActor
    func loadFileURL() async -> URL? {
        guard hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

extension Array where Element == NSItemProvider {
    @MainActor
    func loadFileURLs() async -> [URL] {
        var urls: [URL] = []
        for provider in self {
            if let url = await provider.loadFileURL() { urls.append(url) }
        }
        return urls
    }
}
