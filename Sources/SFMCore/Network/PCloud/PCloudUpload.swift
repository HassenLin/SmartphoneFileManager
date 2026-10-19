import Foundation

/// pCloud 可續傳上傳（分段寫入上傳工作階段，見 `PCloudClient.uploadCreate`）。
///
/// 流程：沿用記錄中相符的工作階段（同一本機檔、大小與修改時間未變、伺服器上還在）→ 以 `upload_info` 的大小為起點；
/// 否則建立新的。每段 `chunkSize` 寫入一次，全部寫完 `upload_save` 存成檔案並刪除記錄。
/// 中斷時記錄保留，下次（重試、繼續、重開 app）從伺服器實際收到的位置接著寫。
enum PCloudUpload {
    /// 每段大小：夠大才不會被請求往返拖慢，夠小才讓一次斷線只損失一段
    static let chunkSize = 32 << 20

    static func run(_ localURL: URL, to path: String, client: PCloudClient, sessions: PCloudUploadSessions,
                    accountID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        let key = PCloudUploadSessions.key(account: accountID, path: path)
        let wanted = PCloudUploadSessions.Record(uploadID: 0, localPath: localURL.path, size: size,
                                                 modified: modified?.timeIntervalSince1970)

        var uploadID: UInt64
        var offset: Int64
        if let saved = sessions.record(for: key), saved.matches(wanted),
           let written = try await client.uploadInfo(saved.uploadID), written <= size {
            uploadID = saved.uploadID
            offset = written
        } else {
            uploadID = try await client.uploadCreate()
            offset = 0
            var record = wanted
            record.uploadID = uploadID
            sessions.set(record, for: key)
        }

        let reader = try FileHandle(forReadingFrom: localURL)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(offset))
        if size > 0 { onProgress(Double(offset) / Double(size)) }
        while offset < size {
            try Task.checkCancellation()
            guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw NetworkError.server("pCloud upload: \(localURL.lastPathComponent) became shorter while uploading")
            }
            let start = offset
            try await client.uploadWrite(uploadID, offset: start, chunk) { sent in
                if size > 0 { onProgress(min(1, Double(start + sent) / Double(size))) }
            }
            offset += Int64(chunk.count)
        }
        try await client.uploadSave(uploadID, to: path, modified: modified)
        sessions.set(nil, for: key)
        onProgress(1)
    }
}

/// 進行中的 pCloud 上傳工作階段記錄（帳號＋遠端路徑 → 工作階段），保存在 Application Support，關閉 app 後仍可續傳。
/// 只記 ID 與本機檔的大小／修改時間；已寫入多少一律以伺服器的 `upload_info` 為準。
public final class PCloudUploadSessions: @unchecked Sendable {
    struct Record: Codable, Equatable {
        var uploadID: UInt64
        var localPath: String
        var size: Int64
        var modified: Double?

        /// 同一個本機檔、內容未變（ID 不比）
        func matches(_ other: Record) -> Bool {
            localPath == other.localPath && size == other.size && modified == other.modified
        }
    }

    private let file: URL
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    public static let standard: PCloudUploadSessions = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PCloudUploadSessions(file: base.appendingPathComponent("SmartphoneFileManager/pcloud-uploads.json"))
    }()

    static func key(account: UUID, path: String) -> String { "\(account.uuidString)|\(RemotePath.normalize(path))" }

    func record(for key: String) -> Record? { lock.withLock { load()[key] } }

    /// nil＝刪除
    func set(_ record: Record?, for key: String) {
        lock.withLock {
            var all = load()
            all[key] = record
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(all).write(to: file, options: .atomic)
            } catch {
                ProcessRunner.log.error("保存 pCloud 上傳記錄失敗：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func load() -> [String: Record] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }
}
