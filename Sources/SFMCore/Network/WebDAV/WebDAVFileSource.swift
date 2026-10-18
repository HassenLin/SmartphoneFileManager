import Foundation

/// WebDAV 伺服器（Synology／QNAP／Nextcloud／Apache…）的檔案來源。
///
/// - 路徑即伺服器路徑（`/home/a.txt`）；帳號的「起始路徑」只是窗格的起始資料夾。
/// - 同來源移動／複製由伺服器完成（MOVE／COPY，`Overwrite: F` 絕不覆蓋）。
/// - 續傳：下載用 Range GET；上傳要伺服器支援部分寫入（第一次續傳時實測，見 `WebDAVClient.partialWriteMethod`），
///   不支援就整份重傳。
public struct WebDAVFileSource: FileSource {
    public let account: NetworkAccount
    let client: WebDAVClient
    let partialWrite: PartialWriteMode

    init(account: NetworkAccount, password: String, options: ConnectionOptions.Resolved) {
        self.account = account
        var comps = URLComponents()
        comps.scheme = account.useTLS ? "https" : "http"
        comps.host = account.host.trimmingCharacters(in: .whitespaces)
        if let port = account.port { comps.port = port }
        // URLComponents 已驗證主機（NetworkAccount.validationError 擋掉含 / 與空白者），這裡不會是 nil
        self.client = WebDAVClient(baseURL: comps.url ?? URL(string: "https://invalid")!, username: account.username,
                                   password: password, pinnedSHA256: account.pinnedCertSHA256, options: options)
        self.partialWrite = options.partialWrite
    }

    public var id: SourceID { account.sourceID }
    public var homePath: String { account.normalizedRootPath }
    public var capabilities: SourceCapabilities { SourceCapabilities(nativeCopy: true, resumable: true) }

    /// 最近一次 TLS 交握看到的憑證指紋（測試連線的「信任此憑證」用）
    public var lastSeenFingerprint: String? { client.lastSeenFingerprint }

    public func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
        let directory = RemotePath.normalize(directory)
        return try await client.propfind(directory, depth: 1)
            .filter { $0.path != directory && (includeHidden || !RemotePath.name(of: $0.path).hasPrefix(".")) }
            .map { FileItem(path: $0.path, isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified) }
    }

    public func isDirectory(_ path: String) async throws -> Bool {
        try await client.entry(path)?.isDirectory ?? false
    }

    public func exists(_ path: String) async throws -> Bool {
        try await client.entry(path) != nil
    }

    public func stat(_ path: String) async throws -> FileStat? {
        try await client.entry(path).map { FileStat(size: $0.size, modified: $0.modified, isDirectory: $0.isDirectory) }
    }

    public func makeDirectory(at path: String) async throws {
        try await client.mkcol(path)
    }

    public func move(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await client.transfer("MOVE", path, to: target, isDirectory: try await isDirectory(path))
        onProgress(1)
    }

    public func copy(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await client.transfer("COPY", path, to: target, isDirectory: try await isDirectory(path))
        onProgress(1)
    }

    /// DELETE 對集合本身就是遞迴（RFC 4918 §9.6.1）
    public func delete(_ path: String) async throws {
        guard RemotePath.normalize(path) != "/" else { throw AdbError.invalidArgument("Refusing to delete /") }
        try await client.delete(path)
    }

    public func download(_ path: String, to localURL: URL, expectedSize: Int64?,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if try await isDirectory(path) {
            return try await NetworkTransfer.downloadDirectory(path, to: localURL, source: self) { [client] remote, local, size in
                try await client.download(remote, to: local, totalSize: size) { _ in }
            }
        }
        try await client.download(path, to: localURL, totalSize: expectedSize, onProgress: onProgress)
    }

    public func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if NetworkTransfer.localIsDirectory(localURL) {
            return try await NetworkTransfer.uploadDirectory(localURL, to: path, source: self, onProgress: onProgress) {
                [client] url, remote, progress in try await client.put(remote, file: url, onProgress: progress)
            }
        }
        try await client.put(path, file: localURL, onProgress: onProgress)
    }

    // MARK: 續傳

    public func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var have = NetworkTransfer.localSize(localURL)
        if have > totalSize || !FileManager.default.fileExists(atPath: localURL.path) { have = 0 }
        guard have < totalSize || totalSize == 0 else { return onProgress(1) }
        try await client.download(path, to: localURL, offset: have, totalSize: totalSize, onProgress: onProgress)
    }

    /// 遠端已有 N 位元組時，從本機第 N 位元組起以 4 MiB 區塊部分寫入；伺服器不支援（或選項關閉）就整份重傳
    public func resumeUpload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let total = NetworkTransfer.localSize(localURL)
        var have = try await stat(path)?.size ?? 0
        if have > total { try await discard(path); have = 0 }
        if have == 0 { return try await upload(localURL, to: path, onProgress: onProgress) }
        guard have < total else { return onProgress(1) }
        let method = partialWrite == .off ? .none : await client.partialWriteMethod(probingIn: RemotePath.parent(of: path))
        guard method != .none else {
            try await discard(path)
            return try await upload(localURL, to: path, onProgress: onProgress)
        }
        let reader = try FileHandle(forReadingFrom: localURL)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(have))
        var offset = have
        while offset < total {
            try Task.checkCancellation()
            guard let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            try await client.write(path, offset: offset, data: chunk, method: method)
            offset += Int64(chunk.count)
            onProgress(Double(offset) / Double(total))
        }
        guard try await stat(path)?.size == total else {
            throw NetworkError.server(String(localized: "Size mismatch after resuming the upload"))
        }
        onProgress(1)
    }
}
