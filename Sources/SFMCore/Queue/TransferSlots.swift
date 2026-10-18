import Foundation

/// 並行傳輸的名額（計數號誌）。同一個工作的所有層級共用一份，所以巢狀資料夾裡的檔案加起來也不超過上限。
///
/// 只有「單檔傳輸」會取得名額，資料夾遍歷本身不佔名額——持有名額的永遠是葉節點，不會互相等待而死結。
/// 取消：等待中的 `acquire` 會拋 `CancellationError`（暫停／停止時不會卡在等名額）。
actor TransferSlots {
    private var free: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(_ count: Int) { free = max(1, count) }

    func acquire() async throws {
        try Task.checkCancellation()
        if free > 0 {
            free -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // 取消可能發生在加入等待之前（此時 onCancel 找不到它）：加入前再檢查一次
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// 歸還名額：有人在等就直接交給最早等的（FIFO，維持大致的檔案順序）
    func release() {
        if waiters.isEmpty {
            free += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    /// 等到名額後執行 `work`，結束（含拋錯）時歸還
    nonisolated func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        return try await runAcquired(work)
    }

    /// 已先取得名額時執行 `work`，結束（含拋錯）時歸還
    nonisolated func runAcquired<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        do {
            let result = try await work()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
