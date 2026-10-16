import AFMCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主視窗目前顯示的面板。同一時間只有一個（SwiftUI `.sheet(item:)` 的限制，也符合原版行為）。
enum ActiveSheet: Identifiable {
    case newFolder
    case newFile
    case rename(RemoteFile)
    case permissions(RemoteFile)
    case copyMove([RemoteFile], move: Bool)
    case addBookmark
    case search
    case clipboard
    case connect
    case deviceInfo
    case appManager
    case imagePreview(ImagePreviewModel)
    case editor(EditorModel)

    var id: String {
        switch self {
        case .newFolder: return "newFolder"
        case .newFile: return "newFile"
        case let .rename(file): return "rename:\(file.path)"
        case let .permissions(file): return "permissions:\(file.path)"
        case let .copyMove(files, move): return "copyMove:\(move):\(files.map(\.path).joined())"
        case .addBookmark: return "addBookmark"
        case .search: return "search"
        case .clipboard: return "clipboard"
        case .connect: return "connect"
        case .deviceInfo: return "deviceInfo"
        case .appManager: return "appManager"
        case let .imagePreview(model): return "image:\(model.file.path)"
        case let .editor(model): return "editor:\(model.file.path)"
        }
    }
}

/// 拖曳時攜帶的裝置端檔案資訊（app 內部型別，拖到本機窗格時使用）
struct RemoteDragItem: Codable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64

    var file: RemoteFile {
        RemoteFile(path: path, name: name, isDirectory: isDirectory, size: size, modified: nil, permissions: "")
    }
}

extension UTType {
    /// 宣告於 Info.plist 的 UTExportedTypeDeclarations（make-app.sh 產生）
    static let remoteFile = UTType(exportedAs: "idv.hassen.adbfilemanager.remote-file", conformingTo: .data)
}

/// App 層協調者：持有各子模型，負責跨窗格（本機 ↔ 裝置）的動作。
///
/// 依賴方向單純：View → AppModel → 子模型 → AFMCore 服務。子模型彼此不互相參考，
/// 需要兩邊資訊的動作（傳輸、開啟檔案）都集中在這裡。
@MainActor
@Observable
final class AppModel {
    let toasts = ToastCenter()
    let transfers = TransferCenter()
    let bookmarks = BookmarkStore()
    let devices = DeviceMonitor()
    let terminals = TerminalStore()
    let remote: RemoteBrowserModel
    let local: LocalBrowserModel

    var sheet: ActiveSheet?
    var pendingDeletion: [RemoteFile] = []
    var pendingInstall: RemoteFile?
    var isLocalPaneCollapsed: Bool {
        didSet { UserDefaults.standard.set(isLocalPaneCollapsed, forKey: SettingsKey.localPaneCollapsed) }
    }

    init() {
        remote = RemoteBrowserModel(devices: devices, toasts: toasts)
        local = LocalBrowserModel(toasts: toasts)
        isLocalPaneCollapsed = UserDefaults.standard.bool(forKey: SettingsKey.localPaneCollapsed)
    }

    func start() {
        devices.start()
        local.reload()
    }

    // MARK: 本機 → 裝置

    func upload(_ urls: [URL], to directory: String? = nil) {
        guard !urls.isEmpty else { return }
        guard let connection = devices.connection else { return toasts.error(AdbError.noDevice) }
        let target = directory ?? remote.path
        let service = RemoteFileService(device: connection)
        // 目的地原本就有的名稱：取消時不能刪（只刪這次新建的不完整檔案）
        let existing = target == remote.path ? Set(remote.files.map(\.name)) : []

        transfers.start(title: String(localized: "Copying to device")) { center in
            for (index, url) in urls.enumerated() {
                center.begin(item: url.lastPathComponent, index: index, count: urls.count)
                let destination = RemotePath.join(target, url.lastPathComponent)
                do {
                    try await service.upload(url, to: destination, onProgress: center.progressSink())
                } catch is CancellationError {
                    if !existing.contains(url.lastPathComponent) {
                        Task.detached { try? await service.delete(destination) }
                    }
                    throw CancellationError()
                }
            }
        } completion: { [self] error in
            if let error {
                error is CancellationError ? toasts.success(String(localized: "Transfer cancelled")) : toasts.error(error)
            } else {
                toasts.success(String(localized: "Copied \(urls.count) item(s) to device"))
                if target == remote.path { remote.pendingHighlight = RemotePath.join(target, urls[0].lastPathComponent) }
            }
            remote.reload()
        }
    }

    /// 本機安裝 APK 到裝置
    func installLocalApk(_ url: URL) {
        guard let connection = devices.connection else { return toasts.error(AdbError.noDevice) }
        transfers.start(title: String(localized: "Installing APK")) { center in
            center.begin(item: url.lastPathComponent, index: 0, count: 1)
            _ = try await connection.install(localApk: url.path)
        } completion: { [toasts] error in
            if let error { toasts.error(error) } else { toasts.success(String(localized: "APK installed")) }
        }
    }

    // MARK: 裝置 → 本機

    /// - Parameter deleteAfter: 「移到本機」＝匯出成功後刪除裝置端來源
    func download(_ files: [RemoteFile], to directory: URL, deleteAfter: Bool = false) {
        guard !files.isEmpty else { return }
        guard let connection = devices.connection else { return toasts.error(AdbError.noDevice) }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            return toasts.error(String(localized: "Folder is not writable: \(directory.path)"))
        }
        let service = RemoteFileService(device: connection)

        transfers.start(title: String(localized: "Copying to Mac")) { center in
            var failures: [String] = []
            for (index, file) in files.enumerated() {
                center.begin(item: file.name, index: index, count: files.count)
                let destination = directory.appendingPathComponent(file.name)
                let existedBefore = FileManager.default.fileExists(atPath: destination.path)
                do {
                    try await service.download(file.path, to: destination,
                                               expectedSize: file.isDirectory ? nil : file.size,
                                               onProgress: center.progressSink())
                    if deleteAfter { try await service.delete(file.path) }
                } catch is CancellationError {
                    if !existedBefore { try? FileManager.default.removeItem(at: destination) }
                    throw CancellationError()
                } catch {
                    failures.append(file.name)
                }
            }
            if !failures.isEmpty {
                throw AdbError.invalidArgument(String(localized: "Failed to copy: \(failures.joined(separator: ", "))"))
            }
        } completion: { [self] error in
            if let error {
                error is CancellationError ? toasts.success(String(localized: "Transfer cancelled")) : toasts.error(error)
            } else {
                toasts.success(String(localized: "Copied \(files.count) item(s) to \(directory.lastPathComponent)"))
            }
            if local.directory == directory.standardizedFileURL {
                local.reload(highlight: directory.appendingPathComponent(files[0].name))
            }
            if deleteAfter { remote.reload() }
        }
    }

    /// 選資料夾後匯出（「匯出到…」）
    func exportWithPanel(_ files: [RemoteFile], deleteAfter: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        panel.directoryURL = local.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        download(files, to: url, deleteAfter: deleteAfter)
    }

    // MARK: 開啟

    /// 雙擊／Return：目錄進入、文字檔編輯、圖片預覽、APK 詢問安裝、其他以預設 App 開啟
    func openRemote(_ file: RemoteFile) {
        if file.isDirectory { return remote.navigate(to: file.path) }
        switch file.kind {
        case .image: previewImage(file)
        case .apk: pendingInstall = file
        default:
            if file.kind.isEditableText || file.size < 64 * 1024 && file.kind == .other {
                edit(file)
            } else {
                openWithDefaultApp(file)
            }
        }
    }

    func edit(_ file: RemoteFile) {
        guard let connection = devices.connection else { return toasts.error(AdbError.noDevice) }
        let editor = EditorModel(file: file, service: RemoteFileService(device: connection), toasts: toasts)
        sheet = .editor(editor)
        editor.load()
    }

    func previewImage(_ file: RemoteFile) {
        guard let connection = devices.connection else { return toasts.error(AdbError.noDevice) }
        let preview = ImagePreviewModel(file: file)
        sheet = .imagePreview(preview)
        preview.load(using: RemoteFileService(device: connection))
    }

    /// 下載到暫存資料夾後交給 macOS 預設 App
    func openWithDefaultApp(_ file: RemoteFile) {
        guard let connection = devices.connection else { return toasts.error(AdbError.noDevice) }
        let service = RemoteFileService(device: connection)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afm-open-\(UUID().uuidString)")
        transfers.start(title: String(localized: "Opening")) { center in
            center.begin(item: file.name, index: 0, count: 1)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await service.download(file.path, to: directory.appendingPathComponent(file.name),
                                       expectedSize: file.size, onProgress: center.progressSink())
        } completion: { [toasts] error in
            if let error { return toasts.error(error) }
            NSWorkspace.shared.open(directory.appendingPathComponent(file.name))
        }
    }

    // MARK: 拖放

    /// 裝置端列的拖曳來源：
    /// 1. app 內部型別（拖到本機窗格 → 走有進度、可取消的 `download`）
    /// 2. 檔案表示（拖到 Finder 等其他 App → 放下時才 pull 到暫存資料夾再交出）
    func dragProvider(for file: RemoteFile) -> NSItemProvider {
        let provider = NSItemProvider()
        let item = RemoteDragItem(path: file.path, name: file.name, isDirectory: file.isDirectory, size: file.size)
        let data = try? JSONEncoder().encode(item)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.remoteFile.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        if let connection = devices.connection {
            provider.suggestedName = file.name
            let type = file.isDirectory ? UTType.folder : (UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afm-drag-\(UUID().uuidString)")
                let destination = directory.appendingPathComponent(file.name)
                Task {
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try await RemoteFileService(device: connection).download(file.path, to: destination, expectedSize: nil) { _ in }
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

    /// 本機窗格的放下處理：裝置端項目 → 下載；Finder 檔案 → 複製進目前目錄
    func handleLocalDrop(_ providers: [NSItemProvider]) -> Bool {
        let remoteProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.remoteFile.identifier) }
        if !remoteProviders.isEmpty {
            Task {
                var files: [RemoteFile] = []
                for provider in remoteProviders {
                    if let data = await provider.loadData(UTType.remoteFile.identifier),
                       let item = try? JSONDecoder().decode(RemoteDragItem.self, from: data) {
                        files.append(item.file)
                    }
                }
                download(files, to: local.directory)
            }
            return true
        }
        Task { local.copyIn(await providers.loadFileURLs()) }
        return true
    }

    /// 裝置端窗格的放下處理：本機檔案 → 上傳到目前目錄（忽略從自己拖出來的項目）
    func handleRemoteDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { !$0.hasItemConformingToTypeIdentifier(UTType.remoteFile.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task { upload(await fileProviders.loadFileURLs()) }
        return true
    }

    // MARK: 裝置工具

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
                if local.directory == downloads.standardizedFileURL { local.reload(highlight: destination) }
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
        await withCheckedContinuation { continuation in
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
        for provider in self where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await provider.loadFileURL() { urls.append(url) }
        }
        return urls
    }
}
