import Foundation

/// 裝置端路徑書籤。JSON 欄位與原版相同（`id`/`name`/`path`/`createdAt`，毫秒），
/// 存在同一個檔案 `~/.adbfilemanager/bookmarks.json`，與 Kotlin 版共用。
public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var path: String
    public var createdAt: Int64

    public init(name: String, path: String, now: Date = Date()) {
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        self.id = millis
        self.name = name
        self.path = path
        self.createdAt = millis
    }
}

/// 書籤檔讀寫（純 I/O，無狀態；UI 層的 `BookmarkStore` 負責可觀察的狀態）。
public struct BookmarkFile: Sendable {
    public let url: URL

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".adbfilemanager/bookmarks.json")) {
        self.url = url
    }

    public func load() -> [Bookmark] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let list = try? JSONDecoder().decode([Bookmark].self, from: data) else { return [] }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ bookmarks: [Bookmark]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(bookmarks).write(to: url, options: .atomic)
    }
}
