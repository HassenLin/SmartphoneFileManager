import Foundation

/// 某來源上的一個資料夾（書籤與同步專案共用）
public struct FolderLocation: Codable, Hashable, Sendable {
    public var source: SourceID
    public var path: String

    public init(source: SourceID, path: String) {
        self.source = source
        self.path = RemotePath.normalize(path)
    }

    /// 舊版（Kotlin 版共用檔）的書籤只有路徑、沒有裝置：以空的 Android 序號表示「任一台 Android」，
    /// 開啟時用窗格目前的 Android 或第一台可用的 Android。
    public var isAnyAndroid: Bool { source.kind == .android && source.deviceID.isEmpty }

    /// 是否屬於某個來源（書籤選單依窗格目前的裝置篩選）；舊版「任一台 Android」書籤屬於每一台 Android
    public func belongs(to id: SourceID) -> Bool {
        source == id || (isAnyAndroid && id.kind == .android)
    }
}

/// 書籤種類一：資料夾書籤
public struct FolderBookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var location: FolderLocation

    public init(id: UUID = UUID(), name: String, location: FolderLocation) {
        self.id = id
        self.name = name
        self.location = location
    }
}

/// 同步方向（左右對應主視窗的左右窗格）
public enum SyncDirection: String, Codable, CaseIterable, Sendable {
    case leftToRight, rightToLeft
    /// 雙向：兩邊各自較新的檔案覆蓋另一邊、只在一邊的檔案拷到另一邊。
    /// 沒有上次同步的紀錄，無法分辨「一邊刪掉」與「另一邊新增」，所以雙向不刪除任何項目
    case twoWay
}

/// 類似 rsync 的選項。
///
/// 通用選項任何來源組合都能用（內建同步引擎 `SyncPlanner` 或 rsync 都支援）；
/// 「rsync 專用」只在兩邊都是這台 Mac 時可用（直接執行 rsync），其他組合的來源做不到
/// （例如裝置無法算檢查碼、無法保留延伸屬性），UI 依 `SyncCapabilities` 隱藏。
public struct SyncOptions: Codable, Hashable, Sendable {
    // MARK: 通用
    /// 刪除目的端有、來源端沒有的項目（rsync `--delete`）。Mac 端由內建引擎刪除時為移到垃圾桶。
    public var deleteExtraneous = false
    /// 包含隱藏檔（`.` 開頭）。不包含時，目的端的隱藏檔也不會被刪除（同 rsync 被排除的檔案受保護）
    public var includeHidden = true
    /// 排除的名稱樣式（glob，比對檔名／資料夾名，例如 `*.tmp`、`node_modules`；rsync `--exclude`）
    public var excludePatterns: [String] = []
    /// 只比大小、不看修改時間（rsync `--size-only`）
    public var sizeOnly = false
    /// 目的端已存在的檔案一律不動（rsync `--ignore-existing`）
    public var ignoreExisting = false

    // MARK: rsync 專用（Mac ↔ Mac）
    /// 以檢查碼比對內容（rsync `-c`），慢但最準
    public var checksum = false
    /// 保留延伸屬性（標籤、Finder 資訊…）
    public var extendedAttributes = false
    /// 額外的 rsync 參數（以 shell 規則切開，例如 `--max-size=1G --dry-run`）
    public var extraArguments = ""

    public init(deleteExtraneous: Bool = false, includeHidden: Bool = true, excludePatterns: [String] = [],
                sizeOnly: Bool = false, ignoreExisting: Bool = false,
                checksum: Bool = false, extendedAttributes: Bool = false, extraArguments: String = "") {
        self.deleteExtraneous = deleteExtraneous
        self.includeHidden = includeHidden
        self.excludePatterns = excludePatterns
        self.sizeOnly = sizeOnly
        self.ignoreExisting = ignoreExisting
        self.checksum = checksum
        self.extendedAttributes = extendedAttributes
        self.extraArguments = extraArguments
    }

    /// 缺少的欄位用預設值（日後新增選項時，舊的書籤／佇列檔仍能讀）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SyncOptions()
        deleteExtraneous = try c.decodeIfPresent(Bool.self, forKey: .deleteExtraneous) ?? d.deleteExtraneous
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? d.includeHidden
        excludePatterns = try c.decodeIfPresent([String].self, forKey: .excludePatterns) ?? d.excludePatterns
        sizeOnly = try c.decodeIfPresent(Bool.self, forKey: .sizeOnly) ?? d.sizeOnly
        ignoreExisting = try c.decodeIfPresent(Bool.self, forKey: .ignoreExisting) ?? d.ignoreExisting
        checksum = try c.decodeIfPresent(Bool.self, forKey: .checksum) ?? d.checksum
        extendedAttributes = try c.decodeIfPresent(Bool.self, forKey: .extendedAttributes) ?? d.extendedAttributes
        extraArguments = try c.decodeIfPresent(String.self, forKey: .extraArguments) ?? d.extraArguments
    }

    /// 名稱是否被排除（隱藏檔設定＋排除樣式）
    public func excludes(_ name: String) -> Bool {
        if !includeHidden && name.hasPrefix(".") { return true }
        return excludePatterns.contains { fnmatch($0, name, 0) == 0 }
    }
}

/// 某個來源組合能用哪些同步選項
public struct SyncCapabilities: Sendable, Equatable {
    /// 兩邊都是這台 Mac：直接執行 rsync（完整選項）
    public let usesRsync: Bool

    public init(from: SourceID, to: SourceID) {
        usesRsync = from == .mac && to == .mac
    }
}

/// 書籤種類二：同步專案（一對資料夾＋方向與選項）
public struct SyncProject: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var left: FolderLocation
    public var right: FolderLocation
    public var direction: SyncDirection
    public var options: SyncOptions

    public init(id: UUID = UUID(), name: String, left: FolderLocation, right: FolderLocation,
                direction: SyncDirection = .leftToRight, options: SyncOptions = SyncOptions()) {
        self.id = id
        self.name = name
        self.left = left
        self.right = right
        self.direction = direction
        self.options = options
    }

    /// 單向的來源／目的；雙向時為左／右（比對與節點以左 → 右為基準方向）
    /// 任一邊在此來源上
    public func involves(_ id: SourceID) -> Bool { left.belongs(to: id) || right.belongs(to: id) }

    public var from: FolderLocation { direction == .rightToLeft ? right : left }
    public var to: FolderLocation { direction == .rightToLeft ? left : right }
}

/// 全部書籤（兩種）
public struct BookmarkLibrary: Codable, Hashable, Sendable {
    public var folders: [FolderBookmark] = []
    public var syncProjects: [SyncProject] = []

    public init(folders: [FolderBookmark] = [], syncProjects: [SyncProject] = []) {
        self.folders = folders
        self.syncProjects = syncProjects
    }
}

/// 書籤庫讀寫：`Application Support/SmartphoneFileManager/bookmarks.json`。
/// 第一次（檔案不存在）時匯入舊版 `~/.adbfilemanager/bookmarks.json`（Android 路徑書籤）；舊檔不修改。
public struct BookmarkLibraryFile: Sendable {
    public let url: URL
    public let legacy: BookmarkFile

    public init(url: URL = QueueStore.standard.directory.appendingPathComponent("bookmarks.json"),
                legacy: BookmarkFile = BookmarkFile()) {
        self.url = url
        self.legacy = legacy
    }

    public func load() -> BookmarkLibrary {
        if let data = try? Data(contentsOf: url), let library = try? JSONDecoder().decode(BookmarkLibrary.self, from: data) {
            return library
        }
        let imported = legacy.load().map {
            FolderBookmark(name: $0.name, location: FolderLocation(source: .android(""), path: $0.path))
        }
        return BookmarkLibrary(folders: imported)
    }

    public func save(_ library: BookmarkLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}
