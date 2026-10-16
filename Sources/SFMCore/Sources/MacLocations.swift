import Foundation

/// Mac 窗格的「位置」捷徑（類似 Finder 側邊欄）。
///
/// 雲端硬碟都放在隱藏的 `~/Library` 底下，逐層瀏覽到不了，所以列成捷徑：
/// - iCloud 雲碟：`~/Library/Mobile Documents/com~apple~CloudDocs`
/// - File Provider 雲端（Google Drive、OneDrive、Dropbox、Box…）：`~/Library/CloudStorage/<Provider>-<帳號>`
/// - 外接／網路磁碟：`/Volumes/*`
public struct MacLocation: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case folder, cloud, volume }
    public let name: String
    public let path: String
    public let kind: Kind
    public var id: String { path }

    public init(name: String, path: String, kind: Kind) {
        self.name = name
        self.path = path
        self.kind = kind
    }
}

extension MacFileSource {
    /// 目前存在的位置：常用資料夾、雲端硬碟、磁碟（不存在者略過）
    public static func locations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [MacLocation] {
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        var result: [MacLocation] = []

        let folders: [(String, String)] = [
            ("Desktop", String(localized: "Desktop")), ("Documents", String(localized: "Documents")),
            ("Downloads", String(localized: "Downloads")),
        ]
        result.append(MacLocation(name: String(localized: "Home"), path: home.path, kind: .folder))
        for (folder, title) in folders where exists(home.appendingPathComponent(folder)) {
            result.append(MacLocation(name: title, path: home.appendingPathComponent(folder).path, kind: .folder))
        }

        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if exists(iCloud) { result.append(MacLocation(name: String(localized: "iCloud Drive"), path: iCloud.path, kind: .cloud)) }
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        let providers = ((try? fm.contentsOfDirectory(atPath: cloudStorage.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for folder in providers {
            result.append(MacLocation(name: cloudDisplayName(folder),
                                      path: cloudStorage.appendingPathComponent(folder).path, kind: .cloud))
        }

        let volumes = ((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for volume in volumes {
            result.append(MacLocation(name: volume, path: "/Volumes/\(volume)", kind: .volume))
        }
        return result
    }

    /// `GoogleDrive-me@gmail.com` → `Google Drive (me@gmail.com)`；`OneDrive-Personal` → `OneDrive (Personal)`。
    /// 資料夾名稱慣例為「供應商-帳號」，供應商名稱本身不含 `-`；不符合慣例的原樣顯示。
    static func cloudDisplayName(_ folder: String) -> String {
        guard let dash = folder.firstIndex(of: "-") else { return folder }
        let provider = String(folder[..<dash])
        let account = String(folder[folder.index(after: dash)...])
        let known = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box",
                     "pCloudDrive": "pCloud Drive", "SynologyDrive": "Synology Drive"]
        let title = known[provider] ?? provider
        return account.isEmpty ? title : "\(title) (\(account))"
    }
}
