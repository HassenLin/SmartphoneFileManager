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
    /// 工作結束（完成／失敗／停止）時通知，app 據此重新載入窗格、顯示提示
    @ObservationIgnored public var onJobFinished: ((TransferJob) -> Void)?

    /// SourceID → 可用的來源（裝置未連線時為 nil）。由 app 在建立後設定（app 的解析需要已初始化的自己）
    @ObservationIgnored public var resolver: (@MainActor (SourceID) -> (any FileSource)?)?
    @ObservationIgnored private let store: QueueStore
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var stopRequested: Set<UUID> = []
    @ObservationIgnored private var answers: [UUID: CheckedContinuation<ConflictAction, Never>] = [:]

    public init(store: QueueStore = .standard) {
        self.store = store
        var loaded = store.load()
        for index in loaded.indices where !loaded[index].state.isFinished {
            loaded[index].state = .paused
            for node in loaded[index].allNodes where node.state == .running {
                loaded[index].updateNode(node.id) { $0.state = $0.operation == .transferFile ? .partial : .pending }
            }
        }
        jobs = loaded
    }

    // MARK: 操作

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
        if !job.state.isFinished { discardPartials(job) }
        store.removeStaging(id)
        jobs.remove(at: index)
        save()
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
        if let index = index(conflict.jobID) {
            if applyToAll { jobs[index].conflictPolicy = action }
            if jobs[index].state == .waitingForUser { jobs[index].state = .running }
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
            let executor = TransferExecutor(
                jobID: id, source: source, destination: destination, staging: store.staging(for: id),
                report: { [weak self] event in await self?.apply(id, event) },
                progress: { nodeID, bytes in buffer.submit(nodeID, bytes) },
                ask: { [weak self] conflict in await self?.ask(conflict) ?? .skip })
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
        guard let index = index(id) else { return }
        conflicts.removeAll { $0.jobID == id }
        if cancelled {
            if stopRequested.contains(id) {
                finishStop(id)
            } else {
                jobs[index].state = .paused
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
        discardPartials(jobs[index])
        store.removeStaging(id)
        jobs[index].state = .stopped
        save()
        onJobFinished?(jobs[index])
    }

    /// 停止／移除時清除未完成檔案節點留在目的的不完整內容
    private func discardPartials(_ job: TransferJob) {
        guard let destinationID = job.destination, let destination = resolver?(destinationID) else { return }
        let targets = job.allNodes.filter { $0.operation == .transferFile && ($0.state == .partial || $0.state == .running) }
            .map(\.targetPath)
        guard !targets.isEmpty else { return }
        Task { for target in targets { try? await destination.discard(target) } }
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
        switch event {
        case let .state(nodeID, state, message):
            jobs[index].updateNode(nodeID) {
                $0.state = state
                $0.message = message
                if state == .done, !$0.isDirectory { $0.transferred = $0.size }
            }
            // 每個節點結束都保存，關閉 app 後才知道從哪裡繼續
            if state != .running { save() }
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
        for (nodeID, bytes) in updates {
            jobs[index].updateNode(nodeID) { if $0.state == .running { $0.transferred = bytes } }
        }
    }

    private func ask(_ conflict: TransferConflict) async -> ConflictAction {
        guard let index = index(conflict.jobID) else { return .skip }
        if let policy = jobs[index].conflictPolicy { return policy }
        jobs[index].state = .waitingForUser
        conflicts.append(conflict)
        return await withCheckedContinuation { answers[conflict.id] = $0 }
    }

    // MARK: 工具

    public func job(_ id: UUID) -> TransferJob? { jobs.first { $0.id == id } }
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
