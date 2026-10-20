import Foundation

/// 裝置時間位移：有的裝置回報 UTC、有的回報本機時間（被當成 UTC 解讀），列表顯示與「誰較新」的比較就差了時區。
///
/// 包住原本的來源，只把 `list`／`stat` 回傳的修改時間加上 `offset`，其餘操作原樣轉給 `base`。
/// 因為窗格顯示、衝突比較（`ConflictAction.resolve`）、同步比對都透過這兩個方法取得時間，
/// 只在這一層調整即可全部一致。修改時間不會寫回裝置（各來源都沒有設定 mtime 的操作），不需反向換算。
///
/// 需要具體來源型別的地方（例如 Android 專屬功能）用 `unwrapped` 取得原本的來源。
public struct TimeShiftedSource: FileSource {
    public let base: any FileSource
    /// 加到裝置回報時間上的秒數（例：裝置回報 UTC、本機為 UTC+8 → +8 小時）
    public let offset: TimeInterval

    public init(_ base: any FileSource, offset: TimeInterval) {
        self.base = base
        self.offset = offset
    }

    /// 位移為 0 時不包裝
    public static func wrap(_ source: any FileSource, offset: TimeInterval) -> any FileSource {
        offset == 0 ? source : TimeShiftedSource(source.unwrapped, offset: offset)
    }

    func shifted(_ date: Date?) -> Date? { date?.addingTimeInterval(offset) }

    // MARK: 調整時間的兩個方法

    public func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
        try await base.list(directory, includeHidden: includeHidden).map {
            FileItem(path: $0.path, name: $0.name, isDirectory: $0.isDirectory, size: $0.size,
                     modified: shifted($0.modified), permissions: $0.permissions)
        }
    }

    public func stat(_ path: String) async throws -> FileStat? {
        try await base.stat(path).map { FileStat(size: $0.size, modified: shifted($0.modified), isDirectory: $0.isDirectory) }
    }

    // MARK: 其餘原樣轉送（含協定有預設實作的成員，才不會落到預設值而失去原本來源的覆寫）

    public var id: SourceID { base.id }
    public var homePath: String { base.homePath }
    public var capabilities: SourceCapabilities { base.capabilities }
    public var maxParallelTransfers: Int { base.maxParallelTransfers }
    public var largeFileThreshold: Int64? { base.largeFileThreshold }
    public var largeFileConnections: Int { base.largeFileConnections }

    public func isDirectory(_ path: String) async throws -> Bool { try await base.isDirectory(path) }
    public func exists(_ path: String) async throws -> Bool { try await base.exists(path) }
    public func makeDirectory(at path: String) async throws { try await base.makeDirectory(at: path) }
    public func move(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.move(path, to: target, onProgress: onProgress)
    }
    public func copy(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.copy(path, to: target, onProgress: onProgress)
    }
    public func delete(_ path: String) async throws { try await base.delete(path) }
    public func discard(_ path: String) async throws { try await base.discard(path) }
    public func download(_ path: String, to localURL: URL, expectedSize: Int64?,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.download(path, to: localURL, expectedSize: expectedSize, onProgress: onProgress)
    }
    public func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.upload(localURL, to: path, onProgress: onProgress)
    }
    public func moveIsInstant(_ path: String, to target: String) async -> Bool { await base.moveIsInstant(path, to: target) }
    public func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.resumeDownload(path, to: localURL, totalSize: totalSize, onProgress: onProgress)
    }
    public func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64, connections: Int,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.resumeDownload(path, to: localURL, totalSize: totalSize, connections: connections, onProgress: onProgress)
    }
    public func resumeUpload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.resumeUpload(localURL, to: path, onProgress: onProgress)
    }
    public func resumeCopy(_ path: String, to target: String, totalSize: Int64,
                           onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.resumeCopy(path, to: target, totalSize: totalSize, onProgress: onProgress)
    }
}

extension FileSource {
    /// 去掉時間位移包裝後的原本來源（需要具體型別時用，例如 `as? AndroidFileSource`）
    public var unwrapped: any FileSource { (self as? TimeShiftedSource)?.base ?? self }
}
