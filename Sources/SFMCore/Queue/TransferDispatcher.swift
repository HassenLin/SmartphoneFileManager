import Foundation

/// 主執行器與子執行器的工作分派（同一個工作共用一份；只有網路帳號會啟用，見 `ExecutorLanes`）。
///
/// 角色：
/// - **主執行器**（1 個）：一律多連線下載，**大檔優先**。取工作順序：主執行器接手的檔案 → 排隊中的大檔 →
///   都沒有時，**接手**子執行器正在跑的大檔（請子執行器停下、保留進度，主執行器以多連線續傳）→ 再沒有才取小檔。
/// - **子執行器**（同時傳輸數 − 1 個）：一律單一連線，**小檔優先**。取工作順序：小檔 → 沒有小檔時取排隊中的大檔
///   （主執行器正在忙；之後主執行器空下來會把它接過去）。
///
/// 遍歷樹的一方（`TransferExecutor.runLevel`）是生產者：`submit` 送出檔案、`result` 等結果。
/// 小檔佇列有上限（子執行器數），滿了生產者就等——資料夾才不會被一口氣全部展開。
///
/// 停留狀態：每個檔案只在一處——`small`／`large`（排隊）、`runningOnSub`（子執行器在跑的大檔，可被接手）、
/// `handoffReady`（子執行器已停下、等主執行器取走）、執行中（不在任何集合）、`results`（完成）。
///
/// 取消：工作被取消時 `cancelAll` 以 `CancellationError` 喚醒所有等待者，之後的呼叫一律拋出。
actor TransferDispatcher {
    final class Item: @unchecked Sendable {
        let id = UUID()
        var node: TransferNode
        let large: Bool
        /// 能否交給主執行器接手（只有「下載到 Mac」：上傳一律單一連線，接手沒有好處）
        let handoffable: Bool
        /// 子執行器執行中的取消方法（接手時呼叫）
        var cancelRunning: (@Sendable () -> Void)?
        var handoffRequested = false

        init(node: TransferNode, large: Bool, handoffable: Bool) {
            self.node = node
            self.large = large
            self.handoffable = handoffable
        }
    }

    let subCount: Int
    private var small: [Item] = []
    private var large: [Item] = []
    private var runningOnSub: [UUID: Item] = [:]
    private var handoffReady: [Item] = []
    /// 已請求接手、子執行器尚未停下的檔案（一次只接手一個）
    private var handoffInFlight: UUID?
    private var results: [UUID: NodeState] = [:]
    private var resultWaiters: [UUID: CheckedContinuation<NodeState, Error>] = [:]
    private var mainWaiter: CheckedContinuation<Item?, Error>?
    private var subWaiters: [CheckedContinuation<Item?, Error>] = []
    private var producerWaiter: CheckedContinuation<Void, Error>?
    /// 遍歷結束、不會再有新檔案
    private var finished = false
    private var cancelled = false

    init(subCount: Int) { self.subCount = max(1, subCount) }

    // MARK: 生產者（遍歷）

    /// 送出一個檔案，回傳之後查結果用的 ID。小檔佇列滿時等子執行器取走
    func submit(_ node: TransferNode, large isLarge: Bool, handoffable: Bool) async throws -> UUID {
        if !isLarge {
            while small.count >= subCount {
                try checkCancelled()
                try await withCheckedThrowingContinuation { producerWaiter = $0 }
            }
        }
        try checkCancelled()
        let item = Item(node: node, large: isLarge, handoffable: handoffable)
        if isLarge { large.append(item) } else { small.append(item) }
        dispatch()
        return item.id
    }

    func result(_ id: UUID) async throws -> NodeState {
        try checkCancelled()
        if let state = results[id] { return state }
        return try await withCheckedThrowingContinuation { resultWaiters[id] = $0 }
    }

    /// 遍歷結束：工作者做完手上的就離開
    func finish() {
        finished = true
        dispatch()
    }

    // MARK: 工作者

    func next(_ lane: ExecutorLane) async throws -> Item? {
        try checkCancelled()
        return try await withCheckedThrowingContinuation { continuation in
            if lane == .main { mainWaiter = continuation } else { subWaiters.append(continuation) }
            dispatch()
        }
    }

    /// 子執行器開始跑一個大檔：登記取消方法（主執行器接手時用）。若接手請求已先到，立即停下
    func started(_ item: Item, cancel: @escaping @Sendable () -> Void) {
        guard item.large else { return }
        item.cancelRunning = cancel
        if item.handoffRequested { cancel() }
    }

    func complete(_ item: Item, _ state: NodeState) {
        runningOnSub[item.id] = nil
        if handoffInFlight == item.id { handoffInFlight = nil }
        results[item.id] = state
        resultWaiters.removeValue(forKey: item.id)?.resume(returning: state)
        dispatch()
    }

    /// 子執行器因接手而停下（進度已保存為 partial）。不是接手請求造成的停止回傳 false（真的被取消）
    func handOff(_ item: Item) -> Bool {
        guard item.handoffRequested, !cancelled else { return false }
        runningOnSub[item.id] = nil
        handoffInFlight = nil
        item.node.state = .partial      // 主執行器直接續傳、不詢問衝突
        handoffReady.append(item)
        dispatch()
        return true
    }

    func cancelAll() {
        cancelled = true
        mainWaiter?.resume(throwing: CancellationError())
        mainWaiter = nil
        for waiter in subWaiters { waiter.resume(throwing: CancellationError()) }
        subWaiters = []
        producerWaiter?.resume(throwing: CancellationError())
        producerWaiter = nil
        for waiter in resultWaiters.values { waiter.resume(throwing: CancellationError()) }
        resultWaiters = [:]
    }

    // MARK: 分派

    /// 每次狀態改變都重新配對：等待中的工作者 ↔ 排隊中的檔案
    private func dispatch() {
        guard !cancelled else { return }
        if let waiter = mainWaiter {
            if !handoffReady.isEmpty {
                mainWaiter = nil
                waiter.resume(returning: handoffReady.removeFirst())
            } else if !large.isEmpty {
                mainWaiter = nil
                waiter.resume(returning: large.removeFirst())
            } else if handoffInFlight == nil,
                      let candidate = runningOnSub.values.first(where: { $0.handoffable && !$0.handoffRequested }) {
                // 主執行器空著、沒有大檔在排隊，但子執行器在跑大檔 → 請它停下交給主執行器（等 handOff 送來）
                candidate.handoffRequested = true
                handoffInFlight = candidate.id
                candidate.cancelRunning?()
            } else if handoffInFlight == nil && !small.isEmpty {
                // 沒有大檔可做、也沒有可接手的：主執行器也處理小檔，不閒著
                mainWaiter = nil
                waiter.resume(returning: small.removeFirst())
            } else if finished && handoffInFlight == nil && small.isEmpty
                        && !runningOnSub.values.contains(where: { $0.handoffable && !$0.handoffRequested }) {
                mainWaiter = nil
                waiter.resume(returning: nil)
            }
        }
        while !subWaiters.isEmpty {
            if !small.isEmpty {
                subWaiters.removeFirst().resume(returning: small.removeFirst())
            } else if !large.isEmpty && mainWaiter == nil {
                // 沒有小檔：取大檔（主執行器在忙；空著的話上面已經先給主執行器）
                let item = large.removeFirst()
                runningOnSub[item.id] = item
                subWaiters.removeFirst().resume(returning: item)
            } else if finished && small.isEmpty && large.isEmpty {
                subWaiters.removeFirst().resume(returning: nil)
            } else {
                break
            }
        }
        if small.count < subCount, let producer = producerWaiter {
            producerWaiter = nil
            producer.resume()
        }
    }

    private func checkCancelled() throws {
        if cancelled { throw CancellationError() }
    }
}
