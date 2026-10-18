import Foundation

/// 單一大檔的多連線下載（HTTP Range；WebDAV 與 pCloud 共用）。
///
/// 做法：檔案切成固定大小的區塊（`blockSize`），`connections` 個工作者輪流領下一個未完成的區塊，
/// 各自以 Range GET 取回後寫到本機檔案的對應位置（不同位置、各自的 FileHandle，互不干擾）。
/// 每完成一個區塊就更新旁邊的隱藏狀態檔（`.名稱.sfm-blocks`），中斷（暫停／關閉 app）後只補未完成的區塊；
/// 全部完成才刪除狀態檔——**狀態檔存在＝檔案尚未完整**（即使大小已經等於總大小）。
///
/// 從單一連線的部分檔案接續時（沒有狀態檔、檔案比總大小小）：已有的前段視為完成的區塊，不必重抓。
enum SegmentedDownload {
    static let blockSize: Int64 = 8 << 20

    struct State: Codable, Equatable {
        var size: Int64
        var block: Int64
        var done: Set<Int>
    }

    /// 狀態檔位置：與目的檔同資料夾的隱藏檔
    static func stateURL(for localURL: URL) -> URL {
        localURL.deletingLastPathComponent().appendingPathComponent("." + localURL.lastPathComponent + ".sfm-blocks")
    }

    static func hasState(_ localURL: URL) -> Bool { FileManager.default.fileExists(atPath: stateURL(for: localURL).path) }

    /// 區塊的位元組範圍（含頭含尾，對應 HTTP `Range: bytes=a-b`）
    static func range(of index: Int, block: Int64, size: Int64) -> ClosedRange<Int64> {
        let start = Int64(index) * block
        return start...min(size, start + block) - 1
    }

    static func blockCount(size: Int64, block: Int64) -> Int { Int((size + block - 1) / block) }

    /// 讀取或建立狀態：沿用相符的狀態檔；否則以既有的前段（單一連線留下的部分檔）推算已完成的區塊
    static func loadState(_ localURL: URL, size: Int64) -> State {
        if let data = try? Data(contentsOf: stateURL(for: localURL)),
           let state = try? JSONDecoder().decode(State.self, from: data), state.size == size, state.block > 0 {
            return state
        }
        let have = FileManager.default.fileExists(atPath: localURL.path) ? NetworkTransfer.localSize(localURL) : 0
        let prefixBlocks = have > 0 && have <= size ? Int(have / blockSize) : 0
        return State(size: size, block: blockSize, done: Set(0..<prefixBlocks))
    }

    /// 執行下載。`fetch` 取回指定範圍的內容（必須剛好是該範圍，呼叫端負責檢查 206）
    static func run(to localURL: URL, totalSize: Int64, connections: Int,
                    onProgress: @escaping @Sendable (Double) -> Void,
                    fetch: @escaping @Sendable (ClosedRange<Int64>) async throws -> Data) async throws {
        let fm = FileManager.default
        let state = loadState(localURL, size: totalSize)
        // 單一連線的部分檔大於狀態推算時也不能截斷前段；只有不存在時才建立
        if !fm.fileExists(atPath: localURL.path) { fm.createFile(atPath: localURL.path, contents: nil) }
        let tracker = Tracker(state: state, stateURL: stateURL(for: localURL), onProgress: onProgress)
        try await tracker.save()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, connections) {
                group.addTask {
                    while let index = await tracker.next() {
                        try Task.checkCancellation()
                        let range = range(of: index, block: state.block, size: totalSize)
                        let data = try await fetch(range)
                        guard Int64(data.count) == Int64(range.count) else {
                            throw NetworkError.server("Range \(range.lowerBound)-\(range.upperBound): got \(data.count) bytes")
                        }
                        let handle = try FileHandle(forWritingTo: localURL)
                        try handle.seek(toOffset: UInt64(range.lowerBound))
                        try handle.write(contentsOf: data)
                        try handle.close()
                        try await tracker.finish(index)
                    }
                }
            }
            try await group.waitForAll()
        }
        // 全部完成：補足長度（最後一塊已寫到結尾，這裡只是防禦）並刪除狀態檔
        let handle = try FileHandle(forWritingTo: localURL)
        try handle.truncate(atOffset: UInt64(totalSize))
        try handle.close()
        try? fm.removeItem(at: stateURL(for: localURL))
        onProgress(1)
    }

    /// 區塊分配與完成記錄（多個工作者共用）
    private actor Tracker {
        private var state: State
        private let stateURL: URL
        private let onProgress: @Sendable (Double) -> Void
        private var pending: [Int]

        init(state: State, stateURL: URL, onProgress: @escaping @Sendable (Double) -> Void) {
            self.state = state
            self.stateURL = stateURL
            self.onProgress = onProgress
            pending = (0..<SegmentedDownload.blockCount(size: state.size, block: state.block))
                .filter { !state.done.contains($0) }
        }

        func next() -> Int? { pending.isEmpty ? nil : pending.removeFirst() }

        func finish(_ index: Int) throws {
            state.done.insert(index)
            try save()
        }

        func save() throws {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            let done = state.done.reduce(Int64(0)) { sum, index in
                sum + Int64(SegmentedDownload.range(of: index, block: state.block, size: state.size).count)
            }
            if state.size > 0 { onProgress(min(1, Double(done) / Double(state.size))) }
        }
    }
}

/// 下載中留在目的檔旁邊的輔助檔（停止／移除工作時一併清除，見 `MacFileSource.discard`）
public enum PartialDownloadFiles {
    public static func sidecars(of localURL: URL) -> [URL] {
        [SegmentedDownload.stateURL(for: localURL),
         localURL.deletingLastPathComponent().appendingPathComponent(localURL.lastPathComponent + ".lftp-pget-status")]
    }
}
