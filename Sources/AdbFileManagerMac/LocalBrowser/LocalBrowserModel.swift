import AFMCore
import AppKit
import SwiftUI

/// 本機窗格狀態。
///
/// 刻意只做「瀏覽 + 傳輸」（與原版相同）：刪除、改名等破壞性本機操作請用 Finder，
/// 這裡只提供「在 Finder 中顯示」。
@MainActor
@Observable
final class LocalBrowserModel {
    private(set) var directory: URL
    private(set) var files: [LocalFile] = []
    private(set) var error: String?
    var selection = Set<LocalFile.ID>()
    var sortType: SortType = .typeAscending {
        didSet { files = sortType.sorted(files) }
    }

    @ObservationIgnored private let toasts: ToastCenter

    init(toasts: ToastCenter) {
        self.toasts = toasts
        let saved = UserDefaults.standard.string(forKey: SettingsKey.defaultExportDirectory)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let preferred = saved.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? downloads
        // 「下載項目／文件／桌面」受 macOS 隱私保護（TCC）：使用者拒絕或尚未授權時讀取會失敗。
        // 起始資料夾讀不到就退回個人專屬資料夾（不受保護），不要一打開就是錯誤畫面。
        if (try? FileManager.default.contentsOfDirectory(atPath: preferred.path)) != nil {
            directory = preferred
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
        }
    }

    /// 目前錯誤是否為 macOS 隱私權限拒絕（可引導使用者到系統設定或以開啟面板授權）
    private(set) var isPermissionError = false

    /// 以開啟面板選資料夾：使用者在面板中明確選取，系統即視為授權存取
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url { navigate(to: url) }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 快速檢查（原版 `isLikelyWritableLocalDirectory`）；實際寫入前仍以真正的檔案操作為準
    var isWritable: Bool { FileManager.default.isWritableFile(atPath: directory.path) }

    var selectedFiles: [LocalFile] { files.filter { selection.contains($0.id) } }

    func files(for ids: Set<LocalFile.ID>) -> [LocalFile] { files.filter { ids.contains($0.id) } }

    func reload(highlight: URL? = nil) {
        let showHidden = UserDefaults.standard.object(forKey: SettingsKey.showHiddenFiles) as? Bool ?? true
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: showHidden ? [] : [.skipsHiddenFiles])
            files = sortType.sorted(urls.map(LocalFile.init))
            error = nil
            isPermissionError = false
        } catch {
            files = []
            self.error = error.localizedDescription
            let nsError = error as NSError
            isPermissionError = nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError
        }
        let ids = Set(files.map(\.id))
        selection.formIntersection(ids)
        if let highlight, ids.contains(highlight.standardizedFileURL) { selection = [highlight.standardizedFileURL] }
    }

    func navigate(to url: URL, highlight: URL? = nil) {
        directory = url.standardizedFileURL
        selection = []
        reload(highlight: highlight)
    }

    func goUp() {
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return }
        navigate(to: parent, highlight: directory)
    }

    func open(_ file: LocalFile) {
        if file.isDirectory {
            navigate(to: file.url)
        } else {
            NSWorkspace.shared.open(file.url)
        }
    }

    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [directory] : urls)
    }

    /// 從 Finder 拖進來的檔案複製到目前目錄（同目錄來源略過）。
    /// 同名時覆寫，與原版 `copyDroppedFilesToDirectory(overwrite = true)` 相同。
    func copyIn(_ urls: [URL]) {
        let fm = FileManager.default
        var copied: URL?
        do {
            for source in urls where source.deletingLastPathComponent().standardizedFileURL != directory {
                let target = directory.appendingPathComponent(source.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: source, to: target)
                copied = copied ?? target
            }
        } catch {
            toasts.error(error)
        }
        reload(highlight: copied)
    }
}
