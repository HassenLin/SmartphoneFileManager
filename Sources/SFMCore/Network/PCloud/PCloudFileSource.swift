import Foundation

/// pCloud 雲端硬碟的檔案來源（美國／歐洲資料中心，見 `PCloudRegion`）。
///
/// - 同來源移動／複製由伺服器完成（renamefile／renamefolder、copyfile／copyfolder）。
/// - 續傳：下載用 Range GET 接續；上傳 `uploadfile` 無法指定位置，衝突時整份重傳，
///   所以 `capabilities.resumable == false`（日後可改用 upload_create／upload_write／upload_save 支援續傳）。
public struct PCloudFileSource: FileSource {
    public let account: NetworkAccount
    let client: PCloudClient

    init(account: NetworkAccount, token: String, options: ConnectionOptions.Resolved) {
        self.account = account
        self.client = PCloudClient(region: account.pcloudRegion, token: token, options: options)
    }

    public var id: SourceID { account.sourceID }
    public var homePath: String { account.normalizedRootPath }
    public var capabilities: SourceCapabilities { SourceCapabilities(nativeCopy: true, resumable: false) }

    public func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
        let directory = RemotePath.normalize(directory)
        return try await client.listFolder(directory)
            .filter { includeHidden || !$0.name.hasPrefix(".") }
            .map { item in
                FileItem(path: RemotePath.join(directory, item.name), name: item.name, isDirectory: item.isfolder,
                         size: item.isfolder ? 0 : (item.size ?? 0), modified: PCloudClient.parseDate(item.modified))
            }
    }

    public func stat(_ path: String) async throws -> FileStat? {
        let path = RemotePath.normalize(path)
        guard path != "/" else { return FileStat(size: 0, modified: nil, isDirectory: true) }
        return try await client.metadata(path).map {
            FileStat(size: $0.isfolder ? 0 : ($0.size ?? 0), modified: PCloudClient.parseDate($0.modified),
                     isDirectory: $0.isfolder)
        }
    }

    public func isDirectory(_ path: String) async throws -> Bool { try await stat(path)?.isDirectory ?? false }
    public func exists(_ path: String) async throws -> Bool { try await stat(path) != nil }

    public func makeDirectory(at path: String) async throws { try await client.createFolder(path) }

    public func move(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await client.rename(path, to: target, isFolder: try await isDirectory(path))
        onProgress(1)
    }

    public func copy(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await client.copy(path, to: target, isFolder: try await isDirectory(path))
        onProgress(1)
    }

    /// pCloud 的刪除會移到 pCloud 自己的垃圾桶（網頁版可復原），但對本 app 而言視為永久刪除
    public func delete(_ path: String) async throws {
        guard RemotePath.normalize(path) != "/" else { throw AdbError.invalidArgument("Refusing to delete /") }
        if try await isDirectory(path) { try await client.deleteFolderRecursive(path) } else { try await client.deleteFile(path) }
    }

    public func download(_ path: String, to localURL: URL, expectedSize: Int64?,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if try await isDirectory(path) {
            return try await NetworkTransfer.downloadDirectory(path, to: localURL, source: self) { [client] remote, local, size in
                try await client.download(remote, to: local, offset: 0, totalSize: size) { _ in }
            }
        }
        try await client.download(path, to: localURL, offset: 0, totalSize: expectedSize, onProgress: onProgress)
    }

    public func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if NetworkTransfer.localIsDirectory(localURL) {
            return try await NetworkTransfer.uploadDirectory(localURL, to: path, source: self, onProgress: onProgress) {
                [client] url, remote, progress in try await client.upload(url, to: remote, onProgress: progress)
            }
        }
        try await client.upload(localURL, to: path, onProgress: onProgress)
    }

    /// pCloud → Mac 的續傳（Range）；上傳方向用預設實作（整份重傳）
    public func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var have = NetworkTransfer.localSize(localURL)
        if have > totalSize || !FileManager.default.fileExists(atPath: localURL.path) { have = 0 }
        guard have < totalSize || totalSize == 0 else { return onProgress(1) }
        try await client.download(path, to: localURL, offset: have, totalSize: totalSize, onProgress: onProgress)
    }
}
