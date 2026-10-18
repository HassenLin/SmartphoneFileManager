import Foundation

/// 網路來源共用的傳輸輔助：資料夾遞迴（協定本身多半只能逐檔傳）與輪詢進度。
///
/// 只依賴 `FileSource` 的單檔操作，所以 WebDAV／FTP／pCloud 共用同一份，不各寫一次遞迴。
enum NetworkTransfer {
    static func localIsDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func localSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Mac 資料夾 → 來源：建立目的資料夾後逐項遞迴；`uploadFile` 只處理單檔。
    /// 進度以「已完成位元組／總位元組」計。
    static func uploadDirectory(_ localURL: URL, to path: String, source: any FileSource,
                                onProgress: @escaping @Sendable (Double) -> Void,
                                uploadFile: @escaping @Sendable (URL, String, @escaping @Sendable (Double) -> Void) async throws -> Void)
    async throws {
        // 先列出全部檔案算總大小，進度才有意義
        let (directories, files) = localTree(localURL, remoteRoot: path)
        let total = files.reduce(Int64(0)) { $0 + localSize($1.0) }
        for directory in directories where !(try await source.exists(directory)) {
            try await source.makeDirectory(at: directory)
        }
        var done: Int64 = 0
        for (url, remote) in files {
            try Task.checkCancellation()
            let size = localSize(url), before = done
            try await uploadFile(url, remote) { fraction in
                if total > 0 { onProgress(min(1, (Double(before) + fraction * Double(size)) / Double(total))) }
            }
            done += size
        }
        onProgress(1)
    }

    /// 本機資料夾樹 → (要建立的遠端資料夾（含根，父在前）, [(本機檔, 遠端路徑)])。
    /// 獨立成同步函式：`FileManager.DirectoryEnumerator` 的迭代不能在 async 環境使用。
    static func localTree(_ localURL: URL, remoteRoot: String) -> ([String], [(URL, String)]) {
        var files: [(URL, String)] = []
        var directories: [String] = [remoteRoot]
        let base = localURL.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: localURL, includingPropertiesForKeys: [.isDirectoryKey])
        else { return (directories, files) }
        while let url = enumerator.nextObject() as? URL {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            let remote = RemotePath.join(remoteRoot, String(relative.drop(while: { $0 == "/" })))
            if localIsDirectory(url) { directories.append(remote) } else { files.append((url, remote)) }
        }
        return (directories, files)
    }

    /// 來源資料夾 → Mac：建立本機資料夾後逐項遞迴
    static func downloadDirectory(_ path: String, to localURL: URL, source: any FileSource,
                                  downloadFile: @escaping @Sendable (String, URL, Int64) async throws -> Void) async throws {
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        for item in try await source.list(path, includeHidden: true) {
            try Task.checkCancellation()
            let target = localURL.appendingPathComponent(item.name)
            if item.isDirectory {
                try await downloadDirectory(item.path, to: target, source: source, downloadFile: downloadFile)
            } else {
                try await downloadFile(item.path, target, item.size)
            }
        }
    }

    /// 執行 `work`，期間每 `interval` 以 `size()` 輪詢已完成大小回報進度
    /// （lftp 在非 TTY 不輸出進度，與 Android 的 adb push 相同手法）
    static func withPolling(total: Int64, interval: Duration = .milliseconds(500),
                            onProgress: @escaping @Sendable (Double) -> Void,
                            size: @escaping @Sendable () async -> Int64,
                            _ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            if total > 0 {
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: interval)
                        onProgress(min(1, Double(await size()) / Double(total)))
                    }
                }
            }
            try await group.next()   // 輪詢迴圈不會自己結束，先完成的一定是 work
            group.cancelAll()
        }
        onProgress(1)
    }
}
