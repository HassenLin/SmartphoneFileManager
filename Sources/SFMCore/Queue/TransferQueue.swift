import Foundation
import Observation

/// 佇列的保存位置：`queue.json` 與經 Mac 中繼時的暫存資料夾（皆在 Application Support，關閉 app 後保留）
public struct QueueStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var standard: QueueStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return QueueStore(directory: base.appendingPathComponent("SmartphoneFileManager", isDirectory: true))
    }

    var file: URL { directory.appendingPathComponent("queue.json") }

    func staging(for jobID: UUID) -> URL {
        directory.appendingPathComponent("staging", isDirectory: true).appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    func load() -> [TransferJob] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([TransferJob].self, from: data)) ?? []
    }

    func save(_ jobs: [TransferJob]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: file, options: .atomic)
        } catch {
            ProcessRunner.log.error("保存工作佇列失敗：\(error.localizedDescription, privacy: .public)")
        }
    }

    func removeStaging(_ jobID: UUID) {
        try? FileManager.default.removeItem(at: staging(for: jobID))
    }
}

/// 拷貝／移動／刪除的工作佇列：樹狀進度、暫停／繼續／停止、關閉 app 後可繼續。
///
/// 併發契約：佇列狀態只在 MainActor 修改；每個執行中的工作是一個 Task，實際傳輸在 `TransferExecutor`
/// （非 MainActor）。狀態事件以 `await` 回到主執行緒套用；進度經 `ProgressBuffer` 合併，主執行緒同時最多一個更新。
///
/// 排程：「每台裝置一次一個工作」——工作的 `lanes`（涉及的裝置）與執行中工作不相交才開始；
/// 裝置未連線的工作保持 pending 並顯示「等待裝置」，裝置清單變動時由 app 呼叫 `schedule()`。
///
/// 持久化：任何狀態轉移立即寫入 `queue.json`；啟動時非終止狀態一律轉為 paused（使用者按繼續才執行），
/// 執行中的檔案節點轉為 partial（繼續時直接續傳、不詢問衝突）。
@MainActor
@Observable
public final class TransferQueue {
    public private(set) var jobs: [TransferJob]
    /// 等待使用者決定的衝突（FIFO；UI 一次顯示第一個）
    public private(set) var conflicts: [TransferConflict] = []
    /// 執行中工作的傳輸速率（工作 ID → 速率）；每次開始執行時重新計算，不保存
    public private(set) var rates: [UUID: TransferRate] = [:]
    /// 傳輸中的檔案由哪個執行器處理（工作 ID → 節點 ID → 執行器）；工作列為每個執行器顯示一條進度
    public private(set) var fileLanes: [UUID: [UUID: ExecutorLane]] = [:]
    /// 每個傳輸中檔案自己的速率（節點 ID → 速率，只計這個檔案的增量）
    public private(set) var fileRates: [UUID: TransferRate] = [:]
    /// 單檔暫時性錯誤的重試等待（測試可縮短）
    @ObservationIgnored public var retry = TransferRetry.standard
    /// 工作結束（完成／失敗／停止）時通知，app 據此重新載入窗格、顯示提示
    @ObservationIgnored public var onJobFinished: ((TransferJob) -> Void)?

    /// SourceID → 可用的來源（裝置未連線時為 nil）。由 app 在建立後設定（app 的解析需要已初始化的自己）
    @ObservationIgnored public var resolver: (@MainActor (SourceID) -> (any FileSource)?)?
    @ObservationIgnored private let store: QueueStore
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var stopRequested: Set<UUID> = []
    /// 剛開始傳輸、還沒收到第一次進度回報的檔案節點：第一次回報只當起點（見 `applyProgress`）
    @ObservationIgnored private var awaitingBaseline: Set<UUID> = []
    @ObservationIgnored private var answers: [UUID: CheckedContinuation<ConflictAction, Never>] = [:]
    /// 執行中工作被使用者移除的節點（與該工作的執行器共用，見 `RemovedNodes`）
    @ObservationIgnored private var removals: [UUID: RemovedNodes] = [:]

    public init(store: QueueStore = .standard) {
        self.store = store
        var loaded = store.load()
        for index in loaded.indices where !loaded[index].state.isFinished {
            loaded[index].state = .paused
            Self.settleRunningNodes(&loaded[index])
        }
        jobs = loaded
    }

    // MARK: 操作

    /// 同步（類似 rsync）：`from` 資料夾的內容單向同步到 `to` 資料夾。
    /// 規劃時才比對兩邊（見 `SyncPlanner`），所以排隊期間的變動也會反映；需要更新的同名檔案一律覆寫。
    @discardableResult
    public func enqueueSync(from: FolderLocation, to: FolderLocation, options: SyncOptions, twoWay: Bool = false) -> UUID {
        var job = TransferJob(kind: .sync, source: from.source, destination: to.source, destinationDirectory: to.path,
                              items: [FileItem(path: from.path, isDirectory: true, size: 0)])
        job.syncOptions = options
        job.syncTwoWay = twoWay
        job.conflictPolicy = .overwrite
        jobs.append(job)
        save()
        schedule()
        return job.id
    }

    @discardableResult
    public func enqueue(_ kind: TransferKind, items: [FileItem], from source: SourceID,
                        to destination: SourceID? = nil, directory: String? = nil) -> UUID? {
        guard !items.isEmpty else { return nil }
        let job = TransferJob(kind: kind, source: source, destination: destination,
                              destinationDirectory: directory, items: items)
        jobs.append(job)
        save()
        schedule()
        return job.id
    }

    public func pause(_ id: UUID) {
        guard let index = index(id) else { return }
        if tasks[id] != nil {
            cancelRunning(id)              // 結束時（finish）轉為 paused
        } else if jobs[index].state == .pending {
            jobs[index].state = .paused
            save()
        }
    }

    public func resume(_ id: UUID) {
        guard let index = index(id), [.paused, .failed, .stopped].contains(jobs[index].state) else { return }
        jobs[index].state = .pending
        jobs[index].message = nil
        save()
        schedule()
    }

    public func stop(_ id: UUID) {
        guard let index = index(id), !jobs[index].state.isFinished || jobs[index].state == .failed else { return }
        stopRequested.insert(id)
        if tasks[id] != nil {
            cancelRunning(id)              // 結束時（finish）清除不完整檔案並轉為 stopped
        } else {
            finishStop(id)
        }
    }

    /// 移出清單（執行中的工作需先暫停或停止）；未完成的工作會先清除不完整檔案
    public func remove(_ id: UUID) {
        guard let index = index(id), tasks[id] == nil else { return }
        let job = jobs[index]
        if !job.state.isFinished { Task { await discardPartials(job) } }
        store.removeStaging(id)
        jobs.remove(at: index)
        save()
    }

    /// 能否從工作移除這個節點：執行中的只有檔案傳輸（可單獨中斷）與資料夾（停止處理剩下的子項）可以；
    /// 刪除、改名、rsync 等一旦開始就無法收回
    public static func canRemove(_ node: TransferNode) -> Bool {
        node.state != .running || node.operation == .transferFile || node.operation == .makeDirectory
    }

    /// 從工作移除一個檔案或資料夾（含其中所有項目）：不再處理。
    /// 正在傳的檔案立即中斷（工作其餘部分照常進行），留在目的端的不完整內容一併清除；
    /// 移動工作裡被移除的項目保留在來源（所屬資料夾因此不會被刪除）。全部移除後工作也移出清單。
    public func removeNode(_ nodeID: UUID, from jobID: UUID) {
        guard let index = index(jobID),
              let node = jobs[index].allNodes.first(where: { $0.id == nodeID }), Self.canRemove(node) else { return }
        let subtree = node.flattened
        let ids = subtree.map(\.id)
        jobs[index].removeNode(nodeID)
        removals[jobID]?.remove(ids)
        for id in ids {
            fileLanes[jobID]?[id] = nil
            fileRates[id] = nil
            awaitingBaseline.remove(id)
        }
        // 正在等使用者回答衝突的檔案：以「略過」解除等待（執行器隨後查到已移除）
        let paths = Set(subtree.map(\.sourcePath))
        for conflict in conflicts where conflict.jobID == jobID && paths.contains(conflict.sourcePath) {
            conflicts.removeAll { $0.id == conflict.id }
            answers.removeValue(forKey: conflict.id)?.resume(returning: .skip)
        }
        if jobs[index].state == .waitingForUser, !conflicts.contains(where: { $0.jobID == jobID }) {
            jobs[index].state = .running
        }
        // 剩下的都成功了：失敗的工作改為完成
        if jobs[index].state == .failed, !jobs[index].allNodes.contains(where: { $0.state == .failed }) {
            jobs[index].state = .completed
        }
        // 不在傳的不完整檔案在這裡清；正在傳的由執行器中斷後自己清（它才知道實際寫到哪裡）
        let partials = subtree.filter { $0.operation == .transferFile && $0.state == .partial }
        let job = jobs[index]
        if !partials.isEmpty {
            Task { await discard(partials, of: job) }
        }
        save()
        if job.planned, job.roots.isEmpty, tasks[jobID] == nil { remove(jobID) }
    }

    public func clearFinished() {
        for job in jobs where job.state.isFinished { store.removeStaging(job.id) }
        jobs.removeAll { $0.state.isFinished }
        save()
    }

    public func pauseAll() { for job in jobs { pause(job.id) } }
    public func resumeAll() { for job in jobs where job.state == .paused { resume(job.id) } }

    /// 衝突對話框的回答
    public func answer(_ conflictID: UUID, action: ConflictAction, applyToAll: Bool) {
        guard let conflict = conflicts.first(where: { $0.id == conflictID }) else { return }
        conflicts.removeAll { $0.id == conflictID }
        if applyToAll {
            // 並行傳輸時同一工作可能已有其他衝突在排隊：一併以同樣的動作回答（執行器會把不能續傳的「續傳」改為覆寫）
            for other in conflicts where other.jobID == conflict.jobID {
                answers.removeValue(forKey: other.id)?.resume(returning: action)
            }
            conflicts.removeAll { $0.jobID == conflict.jobID }
        }
        if let index = index(conflict.jobID) {
            if applyToAll { jobs[index].conflictPolicy = action }
            // 並行時可能還有同工作的其他衝突待回答：全部答完才回到執行中
            if jobs[index].state == .waitingForUser, !conflicts.contains(where: { $0.jobID == conflict.jobID }) {
                jobs[index].state = .running
            }
        }
        answers.removeValue(forKey: conflictID)?.resume(returning: action)
        save()
    }

    // MARK: 排程

    public func schedule() {
        var busy = Set(jobs.filter(\.state.isActive).flatMap(\.lanes))
        for index in jobs.indices where jobs[index].state == .pending {
            let job = jobs[index]
            guard busy.isDisjoint(with: job.lanes) else { continue }
            guard let resolver, let source = resolver(job.source),
                  job.destination.map({ resolver($0) != nil }) ?? true else {
                jobs[index].message = String(localized: "Waiting for device")
                continue
            }
            busy.formUnion(job.lanes)
            start(index, source: source, destination: job.destination.flatMap { resolver($0) })
        }
    }

    private func start(_ index: Int, source: any FileSource, destination: (any FileSource)?) {
        jobs[index].state = .running
        jobs[index].message = nil
        save()
        let id = jobs[index].id
        rates[id] = TransferRate()
        removals[id] = RemovedNodes()
        tasks[id] = Task { await self.execute(id, source: source, destination: destination) }
    }

    private func execute(_ id: UUID, source: any FileSource, destination: (any FileSource)?) async {
        let buffer = ProgressBuffer { [weak self] updates in self?.applyProgress(id, updates) }
        do {
            guard let job = job(id) else { return }
            if !job.planned {
                let roots = try await TransferPlanner.plan(job, source: source, destination: destination)
                guard let index = index(id) else { return }
                jobs[index].roots = roots
                jobs[index].planned = true
                save()
            }
            guard let roots = self.job(id)?.roots else { return }
            // 同時傳輸數：取涉及的非 Mac 來源中最小的上限（Mac 本機不限制；裝置固定 1，所以 手機 ⇄ 雲端 仍逐檔）。
            // ≥ 2 時建立主執行器（大檔）＋子執行器（小檔），執行器依大小分流（見 TransferExecutor）
            let parallel = [source, destination].compactMap { $0 }.filter { $0.id.kind != .mac }
                .map(\.maxParallelTransfers).min() ?? 1
            var executor = TransferExecutor(
                jobID: id, source: source, destination: destination, staging: store.staging(for: id),
                report: { [weak self] event in await self?.apply(id, event) },
                progress: { nodeID, bytes in buffer.submit(nodeID, bytes) },
                ask: { [weak self] conflict in await self?.ask(conflict) ?? .skip },
                options: job.syncOptions, twoWay: job.syncTwoWay == true)
            executor.lanes = ExecutorLanes(parallelTransfers: parallel)
            executor.retry = retry
            if let removed = removals[id] { executor.removed = removed }
            try await executor.run(roots)
            finish(id, cancelled: false)
        } catch is CancellationError {
            finish(id, cancelled: true)
        } catch {
            if let index = index(id) { jobs[index].message = error.localizedDescription }
            finish(id, cancelled: false, failed: true)
        }
    }

    private func finish(_ id: UUID, cancelled: Bool, failed: Bool = false) {
        tasks[id] = nil
        rates[id] = nil
        removals[id] = nil
        for nodeID in (fileLanes[id] ?? [:]).keys { fileRates[nodeID] = nil }
        fileLanes[id] = nil
        guard let index = index(id) else { return }
        conflicts.removeAll { $0.jobID == id }
        if cancelled {
            if stopRequested.contains(id) {
                finishStop(id)
            } else {
                jobs[index].state = .paused
                Self.settleRunningNodes(&jobs[index])
                save()
            }
        } else {
            let nodes = jobs[index].allNodes
            jobs[index].state = failed || nodes.contains { $0.state == .failed } ? .failed : .completed
            if jobs[index].state == .completed { store.removeStaging(id) }
            save()
            onJobFinished?(jobs[index])
        }
        schedule()
    }

    private func finishStop(_ id: UUID) {
        stopRequested.remove(id)
        guard let index = index(id) else { return }
        let job = jobs[index]
        store.removeStaging(id)
        jobs[index].state = .stopped
        save()
        // 先清完目的端的不完整檔案才通知：app 據此重新載入窗格，太早載入會還列出剛被清掉的檔案，
        // 使用者接著對它操作（例如刪除）就會失敗
        Task {
            await discardPartials(job)
            if let finished = self.job(id) { onJobFinished?(finished) }
        }
    }

    /// 停止／移除時清除未完成檔案節點留在目的的不完整內容
    private func discardPartials(_ job: TransferJob) async {
        let nodes = job.allNodes.filter { $0.operation == .transferFile && ($0.state == .partial || $0.state == .running) }
        await discard(nodes, of: job)
    }

    /// 清除這些檔案節點留在目的的不完整內容，以及經 Mac 中繼的暫存檔
    private func discard(_ nodes: [TransferNode], of job: TransferJob) async {
        let staging = store.staging(for: job.id)
        for node in nodes { try? FileManager.default.removeItem(at: staging.appendingPathComponent(node.id.uuidString)) }
        guard let destinationID = job.destination, let destination = resolver?(destinationID) else { return }
        for node in nodes { try? await destination.discard(node.targetPath) }
    }

    private func cancelRunning(_ id: UUID) {
        tasks[id]?.cancel()
        // 正在等待衝突回答的工作：以「略過」解除等待，執行器隨後檢查到取消即結束
        for conflict in conflicts where conflict.jobID == id {
            answers.removeValue(forKey: conflict.id)?.resume(returning: .skip)
        }
        conflicts.removeAll { $0.jobID == id }
    }

    // MARK: 執行器回呼

    private func apply(_ id: UUID, _ event: NodeEvent) {
        guard let index = index(id) else { return }
        // 已被使用者移除的節點：執行器可能還在途中回報，忽略
        if let removed = removals[id], removed.contains(event.nodeID) { return }
        switch event {
        case let .state(nodeID, state, message):
            jobs[index].updateNode(nodeID) {
                // 同一狀態再回報一次但沒帶訊息時保留原訊息（runNode 結束時會再回報一次最終狀態，
                // 不可蓋掉操作自己寫的說明，例如「來源檔案已不存在」）；狀態改變時才清除
                if message != nil || $0.state != state { $0.message = message }
                $0.state = state
                if state == .done, !$0.isDirectory { $0.transferred = $0.size }
            }
            // 每個節點結束都保存，關閉 app 後才知道從哪裡繼續
            if state != .running {
                fileLanes[id]?[nodeID] = nil
                fileRates[nodeID] = nil
                awaitingBaseline.remove(nodeID)
                save()
            }
        case let .fileStarted(nodeID, lane):
            fileLanes[id, default: [:]][nodeID] = lane
            fileRates[nodeID] = TransferRate()
            awaitingBaseline.insert(nodeID)
        case let .expand(nodeID, children):
            jobs[index].updateNode(nodeID) {
                $0.children = children
                $0.expanded = nil
            }
            save()
        case let .retarget(nodeID, path):
            jobs[index].updateNode(nodeID) {
                $0.targetPath = path
                $0.name = RemotePath.name(of: path)
            }
            save()
        }
    }

    private func applyProgress(_ id: UUID, _ updates: [UUID: Int64]) {
        guard let index = index(id) else { return }
        var moved: Int64 = 0
        var perFile: [UUID: Int64] = [:]
        for (nodeID, bytes) in updates {
            // 每個檔案開始後的第一次回報只當起點、不算速率：續傳時它是目的端「已有的大小」，
            // 而節點記錄的 transferred 可能是 0（依規則續傳的新節點）或落後（pCloud 伺服器收到的比記錄多），
            // 差額算進來會讓速率暴衝、剩餘時間跟著錯。新傳的檔案只少算第一次回報的一點點
            let isBaseline = awaitingBaseline.remove(nodeID) != nil
            jobs[index].updateNode(nodeID) {
                guard $0.state == .running else { return }
                if isBaseline {
                    $0.transferred = bytes
                    return
                }
                // 只累計增量（重試後的回報可能比記錄小：不算負值）
                let delta = max(0, bytes - $0.transferred)
                moved += delta
                perFile[nodeID] = delta
                $0.transferred = bytes
            }
        }
        rates[id]?.record(moved)
        for (nodeID, delta) in perFile { fileRates[nodeID]?.record(delta) }
    }

    private func ask(_ conflict: TransferConflict) async -> ConflictAction {
        guard let index = index(conflict.jobID) else { return .skip }
        if let policy = jobs[index].conflictPolicy { return policy }
        jobs[index].state = .waitingForUser
        conflicts.append(conflict)
        return await withCheckedContinuation { answers[conflict.id] = $0 }
    }

    /// 中斷（暫停／關閉 app）後仍標為 running 的節點：檔案轉 partial（繼續時直接續傳），
    /// 資料夾等其他節點轉回 pending——否則暫停的工作裡資料夾仍顯示轉圈，看起來像還在傳
    private static func settleRunningNodes(_ job: inout TransferJob) {
        for node in job.allNodes where node.state == .running {
            job.updateNode(node.id) { $0.state = $0.operation == .transferFile ? .partial : .pending }
        }
    }

    // MARK: 工具

    public func job(_ id: UUID) -> TransferJob? { jobs.first { $0.id == id } }

    /// 工作中正在傳的檔案與其執行器，主執行器在前、子執行器依編號
    public func activeFiles(of job: TransferJob) -> [(node: TransferNode, lane: ExecutorLane)] {
        (fileLanes[job.id] ?? [:]).compactMap { nodeID, lane in job.runningFile(nodeID).map { ($0, lane) } }
            .sorted { $0.lane < $1.lane }
    }
    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }
    private func save() { store.save(jobs) }
}

/// 合併高頻進度：任意執行緒 `submit`，主執行緒同時最多排一個 flush，套用每個節點的最新值
final class ProgressBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: Int64] = [:]
    private var scheduled = false
    private let flush: @MainActor ([UUID: Int64]) -> Void

    init(_ flush: @escaping @MainActor ([UUID: Int64]) -> Void) { self.flush = flush }

    func submit(_ node: UUID, _ bytes: Int64) {
        let schedule: Bool = lock.withLock {
            pending[node] = bytes
            defer { scheduled = true }
            return !scheduled
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            let updates: [UUID: Int64] = lock.withLock {
                defer { pending = [:]; scheduled = false }
                return pending
            }
            MainActor.assumeIsolated { flush(updates) }
        }
    }
}
