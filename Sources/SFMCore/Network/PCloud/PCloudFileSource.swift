import Foundation

/// pCloud 雲端硬碟的檔案來源（美國／歐洲資料中心，見 `PCloudRegion`）。
///
/// - 同來源移動／複製由伺服器完成（renamefile／renamefolder、copyfile／copyfolder）。
/// - 續傳：下載用 Range GET 接續；上傳大於一段（`PCloudUpload.chunkSize`）的檔案走上傳工作階段，
///   中斷後從伺服器已收到的位置接著寫（見 `PCloudUpload`）。工作階段在 `upload_save` 前不會出現在資料夾裡，
///   目的端看不到「部分檔」，所以衝突對話框的「續傳」仍不適用：`capabilities.resumable == false`。
public struct PCloudFileSource: FileSource {
    public let account: NetworkAccount
    let client: PCloudClient
    public let maxParallelTransfers: Int
    public let largeFileThreshold: Int64?
    let options: ConnectionOptions.Resolved
    let uploads: PCloudUploadSessions

    init(account: NetworkAccount, token: PCloudToken, options: ConnectionOptions.Resolved,
         uploads: PCloudUploadSessions = .standard) {
        self.account = account
        self.uploads = uploads
        self.client = PCloudClient(region: account.pcloudRegion, token: token, options: options)
        self.maxParallelTransfers = max(1, options.parallelTransfers)
        self.largeFileThreshold = options.largeFileThreshold
        self.options = options
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
                [self] url, remote, progress in try await uploadFile(url, to: remote, onProgress: progress)
            }
        }
        try await uploadFile(localURL, to: path, onProgress: onProgress)
    }

    /// 單檔上傳：一段就裝得下的小檔用 `uploadfile` 一次送完；較大的走可續傳的上傳工作階段
    /// 本機檔不存在時立即丟出「找不到檔案」：`localSize` 對不存在的檔案回傳 0，會被當成小檔走 `uploadfile`，
    /// URLSession 送出標頭後讀不到內容，伺服器一直等到逾時——看起來像暫時性的網路錯誤而被不斷重試
    private func uploadFile(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: localURL.path])
        }
        if NetworkTransfer.localSize(localURL) <= Int64(PCloudUpload.chunkSize) {
            return try await client.upload(localURL, to: path, onProgress: onProgress)
        }
        try await PCloudUpload.run(localURL, to: path, client: client, sessions: uploads, accountID: account.id,
                                   onProgress: onProgress)
    }

    /// 佇列的續傳上傳：工作階段本身就從中斷處接著寫，不必（也不能）先刪除目的端——目的端在存檔前根本不存在
    public func resumeUpload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await uploadFile(localURL, to: path, onProgress: onProgress)
    }

    /// 停止／移除工作時：連同未存檔的上傳工作階段記錄一併放棄（伺服器上的工作階段會自行過期）
    public func discard(_ path: String) async throws {
        uploads.set(nil, for: PCloudUploadSessions.key(account: account.id, path: path))
        if try await exists(path) { try await delete(path) }
    }

    /// pCloud → Mac 的續傳（Range）；上傳方向用預設實作（整份重傳）
    public var largeFileConnections: Int { max(1, options.maxConnections) }

    public func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await resumeDownload(path, to: localURL, totalSize: totalSize, connections: 1, onProgress: onProgress)
    }

    /// 超過一個區塊：同一個下載連結分區塊（`connections` 條連線；子執行器為 1）
    public func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64, connections: Int,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let segmented = SegmentedDownload.hasState(localURL)
        var have = NetworkTransfer.localSize(localURL)
        if have > totalSize || !FileManager.default.fileExists(atPath: localURL.path) { have = 0 }
        guard have < totalSize || totalSize == 0 || segmented else { return onProgress(1) }
        // 有狀態檔＝上次就是分區塊，一定接著用。超過一個區塊的檔案一律分區塊（單一連線也是）：
        // 每完成一塊就寫入目的檔，斷線不會丟掉已下載的部分（見 SegmentedDownload）
        if segmented || totalSize > SegmentedDownload.blockSize {
            let link = DownloadLink(client: client, path: path)
            return try await SegmentedDownload.run(to: localURL, totalSize: totalSize, connections: max(1, connections),
                                                   onProgress: onProgress) { range in
                try await link.fetch(range)
            }
        }
        try await client.download(path, to: localURL, offset: have, totalSize: totalSize, onProgress: onProgress)
    }
}

/// 多連線下載共用的下載連結。連結數小時後失效，十幾 GB 的檔案可能傳不完：
/// 區塊請求被拒（非 206）時換一個新連結重試該區塊一次
private actor DownloadLink {
    let client: PCloudClient
    let path: String
    private var link: URL?

    init(client: PCloudClient, path: String) {
        self.client = client
        self.path = path
    }

    private func current(refresh: Bool) async throws -> URL {
        if !refresh, let link { return link }
        let fresh = try await client.downloadLink(path)
        link = fresh
        return fresh
    }

    nonisolated func fetch(_ range: ClosedRange<Int64>) async throws -> Data {
        let first = try await current(refresh: false)
        do {
            return try await client.fetchRange(first, range)
        } catch NetworkError.server {
            return try await client.fetchRange(try await current(refresh: true), range)
        }
    }
}
