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
    case iphoneInfo
    case iphoneApps
    case imagePreview(ImagePreviewModel)
    case editor(EditorModel)
    case setupGuide(SetupTopic)

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
        case .iphoneInfo: return "iphoneInfo"
        case .iphoneApps: return "iphoneApps"
        case let .imagePreview(model): return "image:\(model.item.path)"
        case let .editor(model): return "editor:\(model.item.path)"
        case let .setupGuide(topic): return "setup:\(topic.rawValue)"
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
/// 依賴方向：View → AppModel → BrowserModel／DeviceMonitor → SFMCore（FileSource、TransferQueue）。
/// 兩個 BrowserModel 互不參考；需要兩邊資訊的動作都集中在這裡。
@MainActor
@Observable
final class AppModel {
    let toasts = ToastCenter()
    /// 短暫的背景作業（開啟檔案、安裝 APK）
    let transfers = TransferCenter()
    /// 拷貝／移動／刪除的工作佇列（樹狀進度、暫停／繼續／停止、關閉 app 後可繼續）
    let queue = TransferQueue()
    let bookmarks = BookmarkStore()
    /// 網路帳號（WebDAV／FTP／SFTP／pCloud）
    let accounts = AccountStore()
    let devices = DeviceMonitor()
    let terminals = TerminalStore()
    let left: BrowserModel
    let right: BrowserModel

    var sheet: ActiveSheet?
    /// 最後操作的窗格（選取變動時更新）；選單列「新增資料夾」等指令作用在這裡
    var activeSide: PaneSide = .right
    /// 工具列「同步」彈出視窗是否顯示（書籤選單選了同步專案時也由這裡打開）
    var isSyncPopoverPresented = false
    /// 彈出視窗要編輯的同步專案；nil 時以目前左右窗格找既有專案或建立新專案
    var syncProjectToEdit: SyncProject.ID?
    var pendingDeletion: PendingDeletion?
    /// 帳號視窗要選取／新增的帳號（開啟視窗前設定，視窗消化後清空）
    var accountWindowRequest: AccountWindowRequest?
    var pendingInstall: (side: PaneSide, item: FileItem)?
    /// app 內剪貼簿（剪下／拷貝後尚未貼上的項目），狀態列顯示用；實際貼上以系統剪貼簿內容為準
    private(set) var clipboard: FilePayload?
    var isLeftPaneCollapsed: Bool {
        didSet { UserDefaults.standard.set(isLeftPaneCollapsed, forKey: SettingsKey.localPaneCollapsed) }
    }

    @ObservationIgnored private var didAutoSelectRight = false
    /// 網路來源快取（帳號 id → 建立時的帳號庫版本＋來源）：URLSession／TLS 狀態沿用，帳號庫變更即失效
    @ObservationIgnored private var networkSources: [UUID: (revision: Int, source: any FileSource)] = [:]

    init() {
        left = BrowserModel(side: .left, sourceID: Self.savedSource(.left) ?? .mac, toasts: toasts)
        right = BrowserModel(side: .right, sourceID: Self.savedSource(.right), toasts: toasts)
        isLeftPaneCollapsed = UserDefaults.standard.bool(forKey: SettingsKey.localPaneCollapsed)
        queue.resolver = { [weak self] in self?.resolve($0) }
        queue.onJobFinished = { [weak self] in self?.jobFinished($0) }
        accounts.onChange = { [weak self] in self?.accountsDidChange() }
    }

    func pane(_ side: PaneSide) -> BrowserModel { side == .left ? left : right }

    func start() {
        Self.removeStaleTemporaryFiles()
        devices.start()
        refreshSources()
    }

    /// 是否需要 adb：有窗格選了 Android，或有涉及 Android 的待執行工作（排隊、執行中、等待回答）。
    /// 只有這時才輪詢 adb——任何 adb 指令都會啟動常駐的 adb 伺服器（見 `DeviceMonitor.adbWanted`）
    var needsAdb: Bool {
        [left, right].contains { $0.sourceID?.kind == .android }
            || queue.jobs.contains { job in
                [.pending, .running, .waitingForUser].contains(job.state)
                    && (job.source.kind == .android || job.destination?.kind == .android)
            }
    }

    /// `needsAdb` 變動時呼叫（主視窗 onChange）
    func updateAdbWanted() {
        let wanted = needsAdb
        guard devices.adbWanted != wanted else { return }
        devices.adbWanted = wanted
        guard wanted else { return refreshSources() }
        Task {
            await devices.refresh()
            // adb 無法執行（例如設定指向不存在的路徑）：開安裝導引，而不是讓使用者面對空窗格
            if devices.adbError != nil, sheet == nil { sheet = .setupGuide(.android) }
            refreshSources()
        }
    }

    /// 清除上次執行留下的暫存（`afm-` 開頭）：拖到 Finder 的下載（`afm-drag-*`，交出後無人回收）、
    /// 以及被強制結束時殘留的中繼／讀寫暫存。啟動當下不會有進行中的傳輸，可整批刪除。
    /// 例外：`afm-open-*` 是交給其他 App 開啟的副本，對方可能還開著，超過一天才清。
    private static func removeStaleTemporaryFiles() {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        let dayAgo = Date().addingTimeInterval(-86_400)
        for name in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix("afm-") {
            let url = temp.appendingPathComponent(name)
            if name.hasPrefix("afm-open-"),
               let modified = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
               modified > dayAgo { continue }
            try? fm.removeItem(at: url)
        }
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
        // adb 尚未啟用（或還沒找到裝置）：放一個「Android」項目，選了才啟動 adb，找到裝置後自動換成該裝置
        if devices.devices.isEmpty {
            options.append(SourceOption(id: Self.anyAndroid, title: String(localized: "Android"),
                                        symbol: "candybarphone", enabled: true))
        }
        for device in devices.devices {
            options.append(SourceOption(id: .android(device.serial),
                                        title: device.isReady ? device.displayName : "\(device.displayName) — \(device.state)",
                                        symbol: "candybarphone", enabled: device.isReady))
        }
        for phone in devices.iphones {
            options.append(SourceOption(id: .iphone(phone.udid), title: phone.network ? "\(phone.name) (Wi-Fi)" : phone.name,
                                        symbol: phone.network ? "wifi" : "iphone", enabled: true))
        }
        for device in devices.mtpDevices {
            options.append(SourceOption(id: .mtp(device.serial), title: "\(device.name) (MTP)",
                                        symbol: Self.mtpSymbol, enabled: true))
        }
        return options
    }

    /// 來源選單的網路帳號項目（與裝置分開一段；帳號一律可選，連不上時窗格顯示錯誤與處理方式）
    var networkSourceOptions: [SourceOption] {
        accounts.accounts.map { account in
            SourceOption(id: account.sourceID,
                         title: account.isEncrypted ? account.displayName
                             : String(localized: "\(account.displayName) (not encrypted)"),
                         symbol: Self.symbol(for: account.protocol), enabled: true)
        }
    }

    /// 來源選單的「Android」：尚未指定裝置（序號空白，與舊版書籤的「任一台 Android」同一表示法）
    static let anyAndroid = SourceID.android("")

    func title(for id: SourceID?) -> String {
        guard let id else { return String(localized: "Choose a source") }
        if id == Self.anyAndroid { return String(localized: "Android") }
        if let option = sourceOptions.first(where: { $0.id == id }) { return option.title }
        switch id.kind {
        case .network: return accounts.account(for: id)?.displayName ?? String(localized: "Network account (deleted)")
        case .mac: return String(localized: "This Mac")
        case .android: return String(localized: "Android \(id.deviceID) (disconnected)")
        case .iphone: return String(localized: "iPhone (disconnected)")
        case .mtp: return String(localized: "MTP device (disconnected)")
        }
    }

    func symbol(for id: SourceID?) -> String {
        switch id?.kind {
        case .mac: return "laptopcomputer"
        case .android: return "candybarphone"
        case .iphone: return "iphone"
        case .mtp: return Self.mtpSymbol
        case .network: return accounts.account(for: id).map { Self.symbol(for: $0.protocol) } ?? "network.slash"
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
            guard let phone = devices.iphones.first(where: { $0.udid == id.deviceID }),
                  let tool = IPhoneFileSource.locateTool() else { return nil }
            return IPhoneFileSource(udid: id.deviceID, executable: tool, network: phone.network)
        case .mtp:
            return MTPDeviceManager.shared.source(serial: id.deviceID)
        case .network:
            return networkSource(id)
        }
    }

    static func symbol(for networkProtocol: NetworkProtocol) -> String {
        switch networkProtocol {
        case .webdav: return "network"
        case .ftp: return "server.rack"
        case .sftp: return "lock.shield"
        case .pcloud: return "cloud"
        }
    }

    // MARK: 網路來源

    /// 網路帳號 → 來源（快取）。帳號已刪除、缺 lftp、鑰匙圈沒有密碼時為 nil，
    /// 窗格改顯示 `networkUnavailableReason` 說明與處理方式。
    private func networkSource(_ id: SourceID) -> (any FileSource)? {
        guard let account = accounts.account(for: id) else { return nil }
        if let cached = networkSources[account.id], cached.revision == accounts.revision { return cached.source }
        guard let source = try? NetworkSourceFactory.make(account, options: accounts.options(for: account)) else {
            networkSources[account.id] = nil
            return nil
        }
        networkSources[account.id] = (accounts.revision, source)
        return source
    }

    /// 網路來源無法使用的原因（窗格的未連線畫面用）；可用時為 nil
    func networkUnavailableReason(_ id: SourceID?) -> NetworkError? {
        guard let account = accounts.account(for: id) else { return nil }
        do {
            _ = try NetworkSourceFactory.make(account, options: accounts.options(for: account))
            return nil
        } catch let error as NetworkError {
            return error
        } catch {
            return .server(error.localizedDescription)
        }
    }

    /// 帳號庫變更（新增、編輯、刪除、登入／登出）：快取失效，顯示該帳號的窗格以新設定重新連線
    private func accountsDidChange() {
        networkSources = [:]
        for pane in [left, right] where pane.sourceID?.kind == .network {
            pane.replaceSource(resolve(pane.sourceID))
        }
        queue.schedule()
    }

    /// 帳號被哪些地方引用（帳號清單「使用中」欄、刪除確認）
    struct AccountUsage {
        var panes = 0
        var bookmarks = 0
        var syncProjects = 0
        /// 尚未完成的工作（排隊、執行中、暫停）
        var pendingJobs = 0

        var total: Int { panes + bookmarks + syncProjects + pendingJobs }
    }

    func usage(of account: NetworkAccount) -> AccountUsage {
        let id = account.sourceID
        var usage = AccountUsage()
        usage.panes = [left, right].filter { $0.sourceID == id }.count
        usage.bookmarks = bookmarks.folders.filter { $0.location.source == id }.count
        usage.syncProjects = bookmarks.syncProjects.filter { $0.left.source == id || $0.right.source == id }.count
        usage.pendingJobs = queue.jobs.filter { !$0.state.isFinished && ($0.source == id || $0.destination == id) }.count
        return usage
    }

    static let mtpSymbol = "cable.connector"

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
        // 只自動選已連上的裝置，不自動連網路帳號；也不自動選「Android」項目（那會啟動 adb）
        if right.sourceID == nil, !didAutoSelectRight,
           let first = sourceOptions.first(where: { $0.id != .mac && $0.id != Self.anyAndroid && $0.enabled }) {
            didAutoSelectRight = true
            selectSource(first.id, for: .right)
        }
        // 選了「Android」的窗格：adb 找到可用的裝置就換成該裝置
        if let device = devices.devices.first(where: \.isReady) {
            for side in [PaneSide.left, .right] where pane(side).sourceID == Self.anyAndroid {
                selectSource(.android(device.serial), for: side)
            }
        }
        left.updateResolved(resolve(left.sourceID))
        right.updateResolved(resolve(right.sourceID))
        // 裝置接上：等待中的工作可以開始
        queue.schedule()
    }

    /// 從 Finder 拖到路徑列的項目：窗格切到這台 Mac，資料夾直接開啟；檔案開啟所在資料夾並選取它
    func openMacLocation(_ url: URL, in side: PaneSide) {
        let path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        if pane(side).sourceID != .mac { selectSource(.mac, for: side) }
        if isDirectory.boolValue {
            pane(side).navigate(to: path)
        } else {
            pane(side).navigate(to: (path as NSString).deletingLastPathComponent, highlight: path)
        }
        activeSide = side
    }

    /// 某來源內容變了：所有顯示該來源的窗格都重新載入
    func reloadPanes(showing id: SourceID, highlight: [String] = []) {
        for pane in [left, right] where pane.sourceID == id {
            pane.pendingHighlight = Set(highlight)
            pane.reload()
        }
    }

    // MARK: 書籤與同步專案

    /// 窗格目前所在的資料夾
    func location(of side: PaneSide) -> FolderLocation? {
        pane(side).sourceID.map { FolderLocation(source: $0, path: pane(side).path) }
    }

    /// 在窗格開啟某個位置（必要時切換來源）。舊版書籤（任一台 Android）用窗格目前的 Android 或第一台可用的。
    func open(_ location: FolderLocation, in side: PaneSide) {
        var source = location.source
        if location.isAnyAndroid {
            if let current = pane(side).sourceID, current.kind == .android {
                source = current
            } else if let device = devices.devices.first(where: \.isReady) {
                source = .android(device.serial)
            } else {
                // 還沒有可用的裝置（adb 可能尚未啟用）：窗格先切到「Android」以啟動 adb，找到裝置後自動換過去
                if pane(side).sourceID != Self.anyAndroid { selectSource(Self.anyAndroid, for: side) }
                return toasts.error(AdbError.noDevice)
            }
        }
        if pane(side).sourceID != source { selectSource(source, for: side) }
        pane(side).navigate(to: location.path)
    }

    /// 書籤選單選了同步專案：左右窗格開到專案的資料夾，並打開同步彈出視窗
    func openSyncProject(_ project: SyncProject) {
        isLeftPaneCollapsed = false
        open(project.left, in: .left)
        open(project.right, in: .right)
        syncProjectToEdit = project.id
        isSyncPopoverPresented = true
    }

    /// 執行同步：加入工作佇列（裝置未連線時排隊等待）
    func runSync(_ project: SyncProject) {
        queue.enqueueSync(from: project.from, to: project.to, options: project.options,
                          twoWay: project.direction == .twoWay)
        toasts.success(String(localized: "Sync “\(project.name)” added to the task list"))
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

    /// 任意來源 → 某窗格的資料夾：加入工作佇列（規劃、衝突、續傳見 `TransferQueue`）
    func transfer(_ items: [FileItem], from sourceID: SourceID, to side: PaneSide, directory: String? = nil,
                  move: Bool, completion: @escaping @MainActor () -> Void = {}) {
        let destinationPane = pane(side)
        guard !items.isEmpty else { return }
        guard destinationPane.source != nil, let destinationID = destinationPane.sourceID else {
            return toasts.error(String(localized: "The destination is not available"))
        }
        queue.enqueue(move ? .move : .copy, items: items, from: sourceID, to: destinationID,
                      directory: directory ?? destinationPane.path)
        completion()
    }

    /// 工作結束：重新載入相關窗格並提示
    private func jobFinished(_ job: TransferJob) {
        reloadPanes(showing: job.source)
        if let destination = job.destination {
            let completed = job.roots.filter { $0.state == .done }.map(\.targetPath)
            reloadPanes(showing: destination, highlight: completed)
        }
        switch job.state {
        case .completed:
            let count = job.items.count
            switch job.kind {
            case .copy: toasts.success(String(localized: "Copied \(count) item(s)"))
            case .move: toasts.success(String(localized: "Moved \(count) item(s)"))
            case .delete:
                toasts.success(job.source == .mac ? String(localized: "Moved \(count) item(s) to Trash")
                                                  : String(localized: "Deleted \(count) item(s)"))
            case .sync:
                if let rsync = job.rsyncSummary { return toasts.success(rsync) }
                let summary = job.syncSummary
                toasts.success(summary.copied + summary.deleted == 0
                    ? String(localized: "Sync complete: already up to date")
                    : String(localized: "Sync complete: \(summary.copied) file(s) copied, \(summary.deleted) item(s) deleted"))
            }
        case .failed:
            toasts.error(job.message ?? String(localized: "Some items failed. See the task list for details."))
        default:
            break
        }
    }

    /// 「複製／移動到另一窗格」
    func sendToOtherPane(_ items: [FileItem], from side: PaneSide, move: Bool) {
        guard let sourceID = pane(side).sourceID else { return }
        transfer(items, from: sourceID, to: side.other, move: move)
    }

    /// 把非 Mac 項目匯出到選擇的 Mac 資料夾（加入工作佇列）
    func exportWithPanel(_ items: [FileItem], from side: PaneSide) {
        guard let sourceID = pane(side).sourceID else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        queue.enqueue(.copy, items: items, from: sourceID, to: .mac, directory: url.path)
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
        guard let sourceID = pane(pending.side).sourceID else { return }
        // 加入工作佇列；完成時 jobFinished 會更新所有顯示該來源的窗格
        queue.enqueue(.delete, items: pending.items, from: sourceID)
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
    /// 1. 拖曳開始時記錄於 `activeDrag`（窗格之間的放下直接用它，見 `handleInternalDrop`）
    /// 2. 自有型別（僅本 app 可見；`activeDrag` 遺失時的退路）
    /// 3. Mac 項目：檔案 URL（可拖到 Finder／其他 App）
    func dragProvider(for item: FileItem, in side: PaneSide) -> NSItemProvider {
        let browser = pane(side)
        if let sourceID = browser.sourceID { recordDrag(item, from: sourceID) }
        PaneDropDelegate.log.notice("dragProvider \(side.rawValue, privacy: .public) items=\(self.activeDrag?.items.count ?? -1)")
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
        // 裝置上的項目不附帶「拖到 Finder 用」的檔案表示法（registerFileRepresentation）：
        // 系統在拖曳經過任何放下目的地（包括本 app 的窗格）時就要求它準備好，而它必須先整份下載；
        // 實測無論立即下載、拒絕或延後回應，都會讓窗格之間的拖曳卡住（藍框不消失、拖曳無法結束）。
        // 裝置檔案存到 Mac 請用「匯出」或拖到 Mac 窗格。
        return provider
    }

    /// 進行中的 app 內拖曳（拖曳開始時記錄，放下或下一次拖曳時更新）
    struct ActiveDrag {
        let source: SourceID
        var items: [FileItem]
        let startedAt: Date
    }

    @ObservationIgnored private(set) var activeDrag: ActiveDrag?

    /// Table 拖曳多選時，會在同一瞬間對每一列各要一次 item provider：0.5 秒內同來源的視為同一次拖曳
    private func recordDrag(_ item: FileItem, from source: SourceID) {
        if var drag = activeDrag, drag.source == source, Date().timeIntervalSince(drag.startedAt) < 0.5 {
            if !drag.items.contains(item) { drag.items.append(item) }
            activeDrag = drag
        } else {
            activeDrag = ActiveDrag(source: source, items: [item], startedAt: Date())
        }
    }

    /// 窗格之間的放下：直接使用拖曳開始時的紀錄，不載入任何拖曳資料。
    /// 與 Finder 相同：同一來源預設移動（原生 mv），按住 Option 為拷貝；不同來源為拷貝。
    func handleInternalDrop(on side: PaneSide, directory: String? = nil, optionHeld: Bool) -> Bool {
        guard let drag = activeDrag, pane(side).source != nil else {
            PaneDropDelegate.log.notice("handleInternalDrop: 無 activeDrag 或來源不可用")
            return false
        }
        PaneDropDelegate.log.notice("handleInternalDrop \(side.rawValue, privacy: .public) items=\(drag.items.count)")
        activeDrag = nil
        let browser = pane(side)
        let target = directory ?? browser.path
        let items = drag.items.filter {
            !(drag.source == browser.sourceID && RemotePath.parent(of: $0.path) == RemotePath.normalize(target))
        }
        transfer(items, from: drag.source, to: side, directory: target, move: drag.source == browser.sourceID && !optionHeld)
        return true
    }

    /// 放下時的游標提示：同來源且未按 Option 為移動，其餘為拷貝
    func dropOperation(on side: PaneSide, optionHeld: Bool) -> DropOperation {
        guard let drag = activeDrag else { return .copy }
        return drag.source == pane(side).sourceID && !optionHeld ? .move : .copy
    }

    /// 從 Finder／其他 App 放下到窗格（窗格之間的放下見 `handleInternalDrop`）。
    /// 下方仍保留自有型別的處理，作為 `activeDrag` 遺失時的退路。
    /// 與 Finder 相同：**同一來源**（例如左右都是同一台 iPhone）預設為移動，走原生 mv、
    /// 不經 Mac 中繼；按住 Option 才是拷貝。不同來源一律拷貝。
    /// 拖回自己所在的同一資料夾視為不動作，避免誤觸產生副本。
    func handleDrop(_ providers: [NSItemProvider], on side: PaneSide, directory: String? = nil) -> Bool {
        let browser = pane(side)
        guard browser.source != nil else { return false }
        let target = directory ?? browser.path
        // 放下當下的修飾鍵（之後進入 Task 就讀不到了）
        let optionHeld = NSEvent.modifierFlags.contains(.option)
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
            // 依來源分組，各自一次傳輸；只有本 app 窗格拖出的同來源項目才是移動
            for (sourceID, group) in Dictionary(grouping: payloads, by: \.source) {
                let items = group.flatMap(\.items).filter {
                    !(sourceID == browser.sourceID && RemotePath.parent(of: $0.path) == RemotePath.normalize(target))
                }
                let move = sourceID == browser.sourceID && !optionHeld
                transfer(items, from: sourceID, to: side, directory: target, move: move)
            }
            // Finder 拖進來的檔案一律拷貝，不搬走使用者在 Finder 的原檔
            let finderItems = urls.map(Self.macItem).filter {
                !(browser.sourceID == .mac && RemotePath.parent(of: $0.path) == RemotePath.normalize(target))
            }
            transfer(finderItems, from: .mac, to: side, directory: target, move: false)
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
            sheet = .setupGuide(.scrcpy)
            return
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
