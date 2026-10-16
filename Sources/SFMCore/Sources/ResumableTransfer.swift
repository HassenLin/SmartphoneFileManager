import Foundation

/// 檔案資訊（衝突對話框與續傳用）
public struct FileStat: Sendable, Hashable, Codable {
    public let size: Int64
    public let modified: Date?
    public let isDirectory: Bool

    public init(size: Int64, modified: Date?, isDirectory: Bool) {
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
    }
}

/// `FileSource` 工作佇列介面的預設實作：**不續傳**，目的已有部分內容時先清除再整份傳輸。
/// 能真正續傳的來源（Mac、Android、MTP）各自覆寫，並把 `capabilities.resumable` 設為 true。
public extension FileSource {
    func stat(_ path: String) async throws -> FileStat? {
        let path = RemotePath.normalize(path)
        guard path != "/" else { return FileStat(size: 0, modified: nil, isDirectory: true) }
        guard let item = try await list(RemotePath.parent(of: path), includeHidden: true).first(where: { $0.path == path })
        else { return nil }
        return FileStat(size: item.size, modified: item.modified, isDirectory: item.isDirectory)
    }

    func moveIsInstant(_ path: String, to target: String) async -> Bool { true }

    func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: localURL)
        try await download(path, to: localURL, expectedSize: totalSize, onProgress: onProgress)
    }

    func resumeUpload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if try await exists(path) { try await discard(path) }
        try await upload(localURL, to: path, onProgress: onProgress)
    }

    func resumeCopy(_ path: String, to target: String, totalSize: Int64,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if try await exists(target) { try await discard(target) }
        try await copy(path, to: target, onProgress: onProgress)
    }
}

/// 本機檔案的分塊續傳複製（Mac 來源用；`FileManager.copyItem` 無法從中途接續）。
enum LocalResumableCopy {
    static let chunkSize = 8 << 20

    /// `target` 已存在時從其大小接著寫；比來源大則視為無效、從頭來過。每塊之間檢查取消。
    static func copy(from source: URL, to target: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let total = (try fm.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
            var done = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
            if done > total || !fm.fileExists(atPath: target.path) {
                done = 0
                fm.createFile(atPath: target.path, contents: nil)
            }
            let reader = try FileHandle(forReadingFrom: source)
            let writer = try FileHandle(forWritingTo: target)
            defer { try? reader.close(); try? writer.close() }
            try writer.truncate(atOffset: UInt64(done))
            try reader.seek(toOffset: UInt64(done))
            while done < total {
                try Task.checkCancellation()
                guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                try writer.write(contentsOf: chunk)
                done += Int64(chunk.count)
                onProgress(total > 0 ? Double(done) / Double(total) : 1)
            }
            onProgress(1)
        }.value
    }
}
