import AFMCore
import SwiftUI

/// 裝置端窗格狀態（原版 `FileManagerViewModel` 的瀏覽／檔案操作部分）。
///
/// 停留狀態（`Phase`）：`noDevice`／`loading`／`loaded`／`failed`。
/// 跨窗格的傳輸、開啟檔案、各種面板由 `AppModel` 協調，這裡只管「目前目錄」與裝置端操作。
@MainActor
@Observable
final class RemoteBrowserModel {
    enum Phase: Equatable {
        case noDevice, loading, loaded
        case failed(String)
    }

    private(set) var path = RemoteBrowserModel.homePath
    private(set) var files: [RemoteFile] = []
    private(set) var phase: Phase = .noDevice
    private(set) var isBusy = false
    var selection = Set<RemoteFile.ID>()
    /// 輸入即過濾（目前目錄內），遞迴搜尋另見 SearchSheet
    var filterText = ""
    var sortType: SortType {
        didSet {
            files = sortType.sorted(files)
            UserDefaults.standard.set(sortType.rawValue, forKey: SettingsKey.defaultSortType)
        }
    }

    /// 重新載入後要選取的項目（新建、改名、匯入、返回上層後定位用）
    @ObservationIgnored var pendingHighlight: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let devices: DeviceMonitor
    @ObservationIgnored private let toasts: ToastCenter

    static let homePath = "/sdcard"

    init(devices: DeviceMonitor, toasts: ToastCenter) {
        self.devices = devices
        self.toasts = toasts
        self.sortType = SortType(rawValue: UserDefaults.standard.string(forKey: SettingsKey.defaultSortType) ?? "") ?? .typeAscending
    }

    var visibleFiles: [RemoteFile] {
        filterText.isEmpty ? files : files.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var selectedFiles: [RemoteFile] { files.filter { selection.contains($0.id) } }

    func files(for ids: Set<RemoteFile.ID>) -> [RemoteFile] { files.filter { ids.contains($0.id) } }

    func service() throws -> RemoteFileService {
        guard let connection = devices.connection else { throw AdbError.noDevice }
        return RemoteFileService(device: connection)
    }

    // MARK: 瀏覽

    func deviceChanged() {
        path = Self.homePath
        selection = []
        filterText = ""
        reload()
    }

    func reload() {
        loadTask?.cancel()
        guard let connection = devices.connection else {
            files = []
            phase = .noDevice
            return
        }
        phase = .loading
        let path = self.path
        let includeHidden = UserDefaults.standard.object(forKey: SettingsKey.showHiddenFiles) as? Bool ?? true
        loadTask = Task {
            do {
                let list = try await RemoteFileService(device: connection).list(path, includeHidden: includeHidden)
                guard !Task.isCancelled, path == self.path else { return }
                files = sortType.sorted(list)
                phase = .loaded
                let ids = Set(files.map(\.id))
                selection.formIntersection(ids)
                if let highlight = pendingHighlight, ids.contains(highlight) { selection = [highlight] }
                pendingHighlight = nil
            } catch is CancellationError {
            } catch {
                guard path == self.path else { return }
                files = []
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func navigate(to newPath: String, highlight: String? = nil) {
        path = RemotePath.normalize(newPath)
        selection = []
        filterText = ""
        pendingHighlight = highlight
        reload()
    }

    func goUp() {
        guard path != "/" else { return }
        navigate(to: RemotePath.parent(of: path), highlight: path)
    }

    /// 路徑列手動輸入：先確認是可進入的目錄，避免進到錯誤畫面（原版 `checkPermission`）
    func go(toTyped typed: String) {
        let target = RemotePath.normalize(typed.trimmingCharacters(in: .whitespaces))
        Task {
            do {
                if try await service().isDirectory(target) {
                    navigate(to: target)
                } else {
                    toasts.error(AdbError.cannotOpenDirectory(target))
                }
            } catch {
                toasts.error(error)
            }
        }
    }

    // MARK: 裝置端操作

    /// 共用的執行框架：顯示忙碌、成功提示、失敗提示、完成後重新載入
    func perform(success: String?, highlight: String? = nil,
                 _ body: @escaping @MainActor (RemoteFileService) async throws -> Void) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await body(try service())
                if let success { toasts.success(success) }
                pendingHighlight = highlight
            } catch {
                toasts.error(error)
            }
            reload()
        }
    }

    func delete(_ targets: [RemoteFile]) {
        perform(success: nil) { [toasts] service in
            var failures: [String] = []
            for file in targets {
                do { try await service.delete(file.path) } catch { failures.append(file.name) }
            }
            if failures.isEmpty {
                toasts.success(String(localized: "Deleted \(targets.count) item(s)"))
            } else {
                toasts.error(String(localized: "Failed to delete: \(failures.joined(separator: ", "))"))
            }
        }
    }

    func rename(_ file: RemoteFile, to newName: String) {
        let newPath = RemotePath.join(path, newName)
        perform(success: String(localized: "Renamed"), highlight: newPath) { service in
            try await service.rename(file.path, to: newName)
        }
    }

    func makeDirectory(_ name: String) {
        let directory = path
        perform(success: String(localized: "Folder created"), highlight: RemotePath.join(directory, name)) { service in
            try await service.makeDirectory(in: directory, name: name)
        }
    }

    func createFile(_ name: String, contents: String) {
        let directory = path
        perform(success: String(localized: "File created"), highlight: RemotePath.join(directory, name)) { service in
            try await service.createFile(in: directory, name: name, contents: Data(contents.utf8))
        }
    }

    func changeMode(_ file: RemoteFile, mode: String) {
        perform(success: String(localized: "Permissions changed"), highlight: file.path) { service in
            try await service.changeMode(file.path, mode: mode)
        }
    }

    func copyOrMove(_ targets: [RemoteFile], to directory: String, move: Bool) {
        perform(success: nil) { [toasts] service in
            var failures: [String] = []
            for file in targets {
                do {
                    if move { try await service.move(file.path, toDirectory: directory) }
                    else { try await service.copy(file.path, toDirectory: directory) }
                } catch {
                    failures.append(file.name)
                }
            }
            let done = targets.count - failures.count
            if failures.isEmpty {
                toasts.success(move ? String(localized: "Moved \(done) item(s)") : String(localized: "Copied \(done) item(s)"))
            } else {
                toasts.error(String(localized: "\(done) succeeded, failed: \(failures.joined(separator: ", "))"))
            }
        }
    }

    func installApk(_ file: RemoteFile) {
        perform(success: String(localized: "APK installed")) { service in
            _ = try await service.installRemoteApk(file.path)
        }
    }
}
