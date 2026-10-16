import SFMCore
import SwiftUI

/// 書籤庫的可觀察狀態（兩種書籤：資料夾書籤、同步專案）；持久化交給 core 的 `BookmarkLibraryFile`。
@MainActor
@Observable
final class BookmarkStore {
    private(set) var library: BookmarkLibrary
    @ObservationIgnored private let file: BookmarkLibraryFile

    init(file: BookmarkLibraryFile = BookmarkLibraryFile()) {
        self.file = file
        self.library = file.load()
    }

    var folders: [FolderBookmark] { library.folders }
    var syncProjects: [SyncProject] { library.syncProjects }

    // MARK: 資料夾書籤

    func folderBookmark(at location: FolderLocation) -> FolderBookmark? {
        library.folders.first { $0.location == location }
    }

    func addFolder(name: String, location: FolderLocation) throws {
        try mutate { $0.folders.insert(FolderBookmark(name: name, location: location), at: 0) }
    }

    func removeFolder(_ bookmark: FolderBookmark) throws {
        try mutate { $0.folders.removeAll { $0.id == bookmark.id } }
    }

    // MARK: 同步專案

    func syncProject(_ id: SyncProject.ID?) -> SyncProject? {
        library.syncProjects.first { $0.id == id }
    }

    /// 左右資料夾完全相同的專案（同步彈出視窗開啟時找既有專案用）
    func syncProject(left: FolderLocation, right: FolderLocation) -> SyncProject? {
        library.syncProjects.first { $0.left == left && $0.right == right }
    }

    /// 新增或更新（以 id 判斷）
    func saveSyncProject(_ project: SyncProject) throws {
        try mutate { library in
            if let index = library.syncProjects.firstIndex(where: { $0.id == project.id }) {
                library.syncProjects[index] = project
            } else {
                library.syncProjects.insert(project, at: 0)
            }
        }
    }

    func removeSyncProject(_ project: SyncProject) throws {
        try mutate { $0.syncProjects.removeAll { $0.id == project.id } }
    }

    private func mutate(_ body: (inout BookmarkLibrary) -> Void) throws {
        var copy = library
        body(&copy)
        try file.save(copy)
        library = copy
    }
}
