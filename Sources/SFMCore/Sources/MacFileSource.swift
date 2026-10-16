import Foundation

/// Mac 本機檔案系統。刪除一律移到垃圾桶（可復原），只有清除不完整檔案時才永久刪除。
public struct MacFileSource: FileSource {
    public let id = SourceID.mac
    public var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }
    public var capabilities: SourceCapabilities { SourceCapabilities(deleteMovesToTrash: true) }

    public init() {}

    private var fm: FileManager { .default }

    public func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                      .isReadableKey, .isWritableKey, .isExecutableKey]
        let urls = try fm.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: keys,
                                              options: includeHidden ? [] : [.skipsHiddenFiles])
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let permissions = (isDirectory ? "d" : "-")
                + ((values?.isReadable ?? false) ? "r" : "-")
                + ((values?.isWritable ?? false) ? "w" : "-")
                + ((values?.isExecutable ?? false) ? "x" : "-")
            return FileItem(path: url.path, isDirectory: isDirectory, size: Int64(values?.fileSize ?? 0),
                            modified: values?.contentModificationDate, permissions: permissions)
        }
    }

    public func isDirectory(_ path: String) async throws -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func exists(_ path: String) async throws -> Bool { fm.fileExists(atPath: path) }

    public func makeDirectory(at path: String) async throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    /// 同磁碟區為 rename（瞬間）；跨磁碟區由 FileManager 複製後刪除，目前不回報進度
    public func move(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try fm.moveItem(atPath: path, toPath: target)
    }

    public func copy(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard !FileManager.default.fileExists(atPath: target) else {
            throw AdbError.invalidArgument(String(localized: "Target already exists: \(target)"))
        }
        try await Self.copyOffMain(from: URL(fileURLWithPath: path), to: URL(fileURLWithPath: target), onProgress: onProgress)
    }

    public func delete(_ path: String) async throws {
        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    public func discard(_ path: String) async throws {
        try fm.removeItem(atPath: path)
    }

    public func download(_ path: String, to localURL: URL, expectedSize: Int64?,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await Self.copyOffMain(from: URL(fileURLWithPath: path), to: localURL, onProgress: onProgress)
    }

    public func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await Self.copyOffMain(from: localURL, to: URL(fileURLWithPath: path), onProgress: onProgress)
    }

    /// `FileManager.copyItem` 是同步阻塞呼叫，大檔案要放到背景執行緒，避免卡住呼叫端所在的 actor。
    /// 目的已存在時覆寫——與 adb push／afc put -f 的語意一致（編輯器存檔依賴這點；
    /// FileTransfer 一律給不重複的新名稱，不會走到覆寫）。
    static func copyOffMain(from source: URL, to target: URL,
                            onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let total = localSize(source)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            if FileManager.default.fileExists(atPath: target.path) {
                                try FileManager.default.removeItem(at: target)
                            }
                            try FileManager.default.copyItem(at: source, to: target)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
            // copyItem 沒有進度回呼：輪詢目的端已寫出的大小（小於 8MB 不值得輪詢）
            if total > 8 << 20 {
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(300))
                        onProgress(min(1, Double(localSize(target)) / Double(total)))
                    }
                }
            }
            try await group.next()   // 輪詢迴圈不會自己結束，先完成的一定是複製
            group.cancelAll()
        }
        onProgress(1)
    }

    /// 檔案大小，或資料夾內所有檔案大小總和；不存在時為 0
    static func localSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
