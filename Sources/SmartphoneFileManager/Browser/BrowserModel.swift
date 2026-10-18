import SFMCore
import SwiftUI

enum PaneSide: String, Sendable {
    case left, right

    var other: PaneSide { self == .left ? .right : .left }
}

/// 一個檔案窗格的狀態。左右兩個窗格是同一個型別，各自選擇來源（Mac／Android／iPhone）。
///
/// 停留狀態（`Phase`）：
/// - `noSource`：尚未選擇來源
/// - `unavailable`：選了的裝置目前沒連上（保留選擇，重新連上後自動恢復）
/// - `loading`／`loaded`／`failed`
/// 跨窗格的動作（傳輸、剪貼簿、開啟檔案）由 `AppModel` 協調；這裡只管「目前目錄」與單一來源內的操作。
@MainActor
@Observable
final class BrowserModel {
    enum Phase: Equatable {
        case noSource
        case unavailable
        case loading
        case loaded
        case failed(String)
    }

    let side: PaneSide
    private(set) var sourceID: SourceID?
    private(set) var source: (any FileSource)?
    private(set) var path = "/" {
        didSet { rememberPath() }
    }
    private(set) var files: [FileItem] = []
    private(set) var phase: Phase = .noSource
    private(set) var isBusy = false
    var selection = Set<FileItem.ID>()
    var filterText = ""
    var sortType: SortType {
        didSet { files = sortType.sorted(files) }
    }

    @ObservationIgnored var pendingHighlight: Set<String> = []
    /// 顯示名稱與路徑最後一段不同的項目（iPhone App 資料夾：路徑是 bundle id、顯示 App 名稱），路徑列用
    private(set) var displayNames: [String: String] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// 每個來源最後停留的資料夾：切換來源再切回來、或下次啟動時恢復（存於 UserDefaults，每個窗格一份）
    @ObservationIgnored private var lastPaths: [SourceID: String] = [:]
    /// 目前路徑是「恢復的」而非使用者剛點進去的：載入失敗（資料夾已不存在）時退回起始資料夾，而不是停在錯誤畫面
    @ObservationIgnored private var isRestoredPath = false
    @ObservationIgnored private let toasts: ToastCenter

    init(side: PaneSide, sourceID: SourceID?, toasts: ToastCenter) {
        self.side = side
        self.sourceID = sourceID
        self.toasts = toasts
        self.sortType = SortType(rawValue: UserDefaults.standard.string(forKey: SettingsKey.defaultSortType) ?? "") ?? .typeAscending
        self.lastPaths = Self.loadPaths(side)
        if let sourceID, let saved = lastPaths[sourceID] {
            path = saved
            isRestoredPath = true
        } else if sourceID == .mac {
            path = Self.defaultMacPath()
        }
    }

    // MARK: 路徑記憶

    private static func pathsKey(_ side: PaneSide) -> String { "panePaths.\(side.rawValue)" }

    /// UserDefaults 只收字串鍵：`kind:deviceID` → 路徑
    private static func storageKey(_ id: SourceID) -> String { "\(id.kind.rawValue):\(id.deviceID)" }

    private static func loadPaths(_ side: PaneSide) -> [SourceID: String] {
        let stored = UserDefaults.standard.dictionary(forKey: pathsKey(side)) as? [String: String] ?? [:]
        var paths: [SourceID: String] = [:]
        for (key, path) in stored {
            let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let kind = SourceID.Kind(rawValue: String(parts[0])) else { continue }
            paths[SourceID(kind: kind, deviceID: String(parts[1]))] = path
        }
        return paths
    }

    private func rememberPath() {
        guard let sourceID else { return }
        lastPaths[sourceID] = path
        let stored = Dictionary(uniqueKeysWithValues: lastPaths.map { (Self.storageKey($0.key), $0.value) })
        UserDefaults.standard.set(stored, forKey: Self.pathsKey(side))
    }

    /// 起始資料夾（恢復失敗時的退路）
    private var startPath: String {
        sourceID == .mac ? Self.defaultMacPath() : (source?.homePath ?? "/")
    }

    var visibleFiles: [FileItem] {
        filterText.isEmpty ? files : files.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var selectedFiles: [FileItem] { files.filter { selection.contains($0.id) } }

    func files(for ids: Set<FileItem.ID>) -> [FileItem] { files.filter { ids.contains($0.id) } }

    var capabilities: SourceCapabilities { source?.capabilities ?? SourceCapabilities() }

    /// 目前來源若為 Android，回傳其 adb 來源（chmod、安裝 APK、搜尋用）
    var androidSource: AndroidFileSource? { source as? AndroidFileSource }

    // MARK: 來源

    /// 使用者在窗格選單選擇來源
    func select(_ id: SourceID, resolved: (any FileSource)?) {
        guard id != sourceID else { return }
        sourceID = id
        source = resolved
        isRestoredPath = lastPaths[id] != nil
        path = lastPaths[id] ?? (id == .mac ? Self.defaultMacPath() : (resolved?.homePath ?? "/"))
        selection = []
        filterText = ""
        reload()
    }

    /// 裝置清單變動時由 AppModel 呼叫；可用性改變（拔掉／接上／授權）才重新載入
    func updateResolved(_ resolved: (any FileSource)?) {
        let wasAvailable = source != nil
        let executableChanged = (source as? AndroidFileSource)?.device != (resolved as? AndroidFileSource)?.device
        source = resolved
        if wasAvailable != (resolved != nil) || executableChanged {
            if resolved != nil, path == "/", sourceID != .mac, !isRestoredPath { path = resolved!.homePath }
            reload()
        }
    }

    /// 來源本身換了（網路帳號改了設定）：一律以新來源重新載入目前資料夾
    func replaceSource(_ resolved: (any FileSource)?) {
        source = resolved
        reload()
    }

    /// Mac 窗格的起始資料夾：設定值 → 下載項目 → 個人專屬資料夾。
    /// 「下載項目」受 macOS 隱私保護（TCC），讀不到就退回個人專屬資料夾，避免一開就是錯誤畫面。
    static func defaultMacPath() -> String {
        let fm = FileManager.default
        let saved = UserDefaults.standard.string(forKey: SettingsKey.defaultExportDirectory)
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        for candidate in [saved, downloads].compactMap({ $0 }) where (try? fm.contentsOfDirectory(atPath: candidate)) != nil {
            return candidate
        }
        return fm.homeDirectoryForCurrentUser.path
    }

    // MARK: 瀏覽

    func reload() {
        loadTask?.cancel()
        guard sourceID != nil else { phase = .noSource; files = []; return }
        guard let source else { phase = .unavailable; files = []; return }
        phase = .loading
        let path = self.path
        let includeHidden = UserDefaults.standard.object(forKey: SettingsKey.showHiddenFiles) as? Bool ?? true
        loadTask = Task {
            do {
                let list = try await source.list(path, includeHidden: includeHidden)
                guard !Task.isCancelled, path == self.path else { return }
                files = sortType.sorted(list)
                for item in list where item.name != RemotePath.name(of: item.path) {
                    displayNames[item.path] = item.name
                }
                phase = .loaded
                isRestoredPath = false
                let ids = Set(files.map(\.id))
                selection.formIntersection(ids)
                let highlight = pendingHighlight.intersection(ids)
                if !highlight.isEmpty { selection = highlight }
                pendingHighlight = []
            } catch is CancellationError {
            } catch {
                guard path == self.path else { return }
                // 恢復的資料夾已不存在／無權限：改到起始資料夾（只退一次，避免起始資料夾也失敗時來回重試）
                if isRestoredPath, source.id == sourceID, path != startPath {
                    isRestoredPath = false
                    navigate(to: startPath)
                    return
                }
                isRestoredPath = false
                files = []
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func navigate(to newPath: String, highlight: String? = nil) {
        isRestoredPath = false
        path = RemotePath.normalize(newPath)
        selection = []
        filterText = ""
        pendingHighlight = highlight.map { [$0] } ?? []
        reload()
    }

    func goUp() {
        guard path != "/" else { return }
        navigate(to: RemotePath.parent(of: path), highlight: path)
    }

    func goHome() {
        guard let source else { return }
        navigate(to: source.id == .mac ? Self.defaultMacPath() : source.homePath)
    }

    /// 路徑列手動輸入：先確認是可進入的資料夾
    func go(toTyped typed: String) {
        guard let source else { return }
        var text = typed.trimmingCharacters(in: .whitespaces)
        if source.id == .mac { text = (text as NSString).expandingTildeInPath }
        let target = RemotePath.normalize(text)
        Task {
            if (try? await source.isDirectory(target)) == true {
                navigate(to: target)
            } else {
                toasts.error(AdbError.cannotOpenDirectory(target))
            }
        }
    }

    // MARK: 單一來源內的操作

    /// 共用執行框架：忙碌狀態、成功提示、失敗提示、完成後重新載入並選取新項目
    func perform(success: String?, highlight: String? = nil,
                 _ body: @escaping @MainActor (any FileSource) async throws -> Void) {
        guard let source else { return toasts.error(AdbError.noDevice) }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await body(source)
                if let success { toasts.success(success) }
                pendingHighlight = highlight.map { [$0] } ?? []
            } catch {
                toasts.error(error)
            }
            reload()
        }
    }

    func makeDirectory(_ name: String) {
        let target = RemotePath.join(path, name)
        perform(success: String(localized: "Folder created"), highlight: target) { source in
            try FileName.validate(name)
            try await source.makeDirectory(at: target)
        }
    }

    func createFile(_ name: String, contents: String) {
        let target = RemotePath.join(path, name)
        perform(success: String(localized: "File created"), highlight: target) { source in
            try FileName.validate(name)
            if try await source.exists(target) {
                throw AdbError.invalidArgument(String(localized: "Target already exists: \(target)"))
            }
            try await source.write(Data(contents.utf8), to: target)
        }
    }

    func rename(_ item: FileItem, to newName: String) {
        let target = RemotePath.join(RemotePath.parent(of: item.path), newName)
        perform(success: String(localized: "Renamed"), highlight: target) { source in
            try FileName.validate(newName)
            if try await source.exists(target) {
                throw AdbError.invalidArgument(String(localized: "Target already exists: \(target)"))
            }
            try await source.move(item.path, to: target)
        }
    }

    /// 刪除（Mac 為移到垃圾桶）。逐項執行，失敗的項目彙整後一次回報。
    func changeMode(_ item: FileItem, mode: String) {
        perform(success: String(localized: "Permissions changed"), highlight: item.path) { source in
            guard let android = source as? AndroidFileSource else { return }
            try await android.changeMode(item.path, mode: mode)
        }
    }

    func installApk(_ item: FileItem) {
        perform(success: String(localized: "APK installed")) { source in
            guard let android = source as? AndroidFileSource else { return }
            _ = try await android.installApk(item.path)
        }
    }
}
