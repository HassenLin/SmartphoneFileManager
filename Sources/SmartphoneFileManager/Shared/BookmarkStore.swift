import SFMCore
import SwiftUI

/// 書籤的可觀察狀態；持久化交給 core 的 `BookmarkFile`（與 Kotlin 版共用同一個 JSON 檔）。
@MainActor
@Observable
final class BookmarkStore {
    private(set) var bookmarks: [Bookmark]
    @ObservationIgnored private let file: BookmarkFile

    init(file: BookmarkFile = BookmarkFile()) {
        self.file = file
        self.bookmarks = file.load()
    }

    func contains(path: String) -> Bool { bookmarks.contains { $0.path == path } }

    func add(name: String, path: String) throws {
        bookmarks.insert(Bookmark(name: name, path: path), at: 0)
        try file.save(bookmarks)
    }

    func remove(_ bookmark: Bookmark) throws {
        bookmarks.removeAll { $0.path == bookmark.path && $0.name == bookmark.name }
        try file.save(bookmarks)
    }
}
