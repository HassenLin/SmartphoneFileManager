import Foundation

/// 單檔傳輸由哪個執行器處理（UI 依此為每個執行器的進度條上不同顏色）
public enum ExecutorLane: Sendable, Hashable, Comparable {
    /// 大檔（或逐檔時的全部檔案）；下載用多條連線
    case main
    /// 小檔；單一連線。編號 0…子執行器數−1（只用於區分顯示，分派不看編號）
    case sub(Int)
}

/// 主執行器＋子執行器的組態（佇列依同時傳輸數建立；實際分派見 `TransferDispatcher`）。
///
/// **只用於雲端（網路帳號）**：只有網路帳號的同時傳輸數可以 > 1（Mac 與手機的 `maxParallelTransfers` 固定 1），
/// 所以涉及手機或只有 Mac 的工作不會建立，維持逐檔。
struct ExecutorLanes: Sendable, Equatable {
    /// 子執行器數（同時傳輸數 − 1）；主執行器固定 1 個
    let subCount: Int

    /// 同時傳輸數 < 2 時為 nil（逐檔，唯一的執行器即主執行器）
    init?(parallelTransfers: Int) {
        guard parallelTransfers >= 2 else { return nil }
        subCount = parallelTransfers - 1
    }
}

/// 執行器回報給佇列的節點事件（佇列在主執行緒套用並保存）。
/// 以 `await` 回報、套用完才繼續，確保佇列判定工作結束時所有事件都已套用；
/// 高頻的進度另走不等待、會合併的 `progress` 閉包。
enum NodeEvent: Sendable {
    case state(UUID, NodeState, message: String? = nil)
    /// 衝突選「重新命名」後的新目的路徑
    case retarget(UUID, path: String)
    /// 資料夾執行到時才列出的內容（佇列寫入樹並保存，繼續時不必重新列出）
    case expand(UUID, children: [TransferNode])
    /// 某個執行器開始傳這個檔案（工作列為每個執行器顯示一條進度）
    case fileStarted(UUID, lane: ExecutorLane)

    var nodeID: UUID {
        switch self {
        case let .state(id, _, _), let .retarget(id, _), let .expand(id, _), let .fileStarted(id, _): return id
        }
    }
}

/// 使用者從執行中工作移除的節點（佇列在主執行緒寫入、執行器在背景查詢，以鎖保護）。
///
/// 執行器拿的是開始時的樹（快照），看不到佇列之後的修改，所以移除要經過這裡：
/// - 還沒輪到的節點：執行器輪到時查到已移除，直接略過（不回報）。
/// - 傳輸中的檔案：執行器開始傳時登記中斷方式，移除時立即中斷，執行器清掉目的端的不完整內容。
/// - 執行中的資料夾：之後才列出的子項不在佇列的樹裡，由資料夾那一層查「上層已移除」就停（見 `runLevel`）。
final class RemovedNodes: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []
    private var cancels: [UUID: @Sendable () -> Void] = [:]

    func contains(_ id: UUID) -> Bool {
        lock.withLock { ids.contains(id) }
    }

    /// 標為已移除；其中正在傳的檔案立即中斷
    func remove(_ newIDs: [UUID]) {
        let toCancel = lock.withLock {
            ids.formUnion(newIDs)
            return newIDs.compactMap { cancels.removeValue(forKey: $0) }
        }
        toCancel.forEach { $0() }
    }

    /// 開始傳檔案時登記中斷方式；已被移除時回傳 false（呼叫端自己中斷）
    func register(_ id: UUID, cancel: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard !ids.contains(id) else { return false }
            cancels[id] = cancel
            return true
        }
    }

    func unregister(_ id: UUID) {
        _ = lock.withLock { cancels.removeValue(forKey: id) }
    }
}

/// 依工作樹逐節點執行（深度優先）。不持有狀態：每次繼續都以佇列保存的樹重新進入，
/// 已完成／略過的節點直接跳過，`partial` 的節點以 `resume*` 從中斷處接著做。
///
/// 取消（暫停／停止／關閉 app）：正在傳的檔案標為 `partial` 並保留不完整內容，再往上拋 `CancellationError`；
/// 停止時由佇列負責清除這些不完整內容。其他錯誤只讓該節點失敗，繼續處理其餘節點。
///
/// **主執行器／子執行器**（只用於雲端：網路帳號「同時傳輸數」≥ 2 時，見 `ExecutorLanes`、`TransferDispatcher`）：
/// 遍歷樹時依檔案大小分流——達到大檔門檻的交給**主執行器**（一次一個）、其餘交給**子執行器**（同時傳輸數 − 1 個）。
/// 子執行器沒有小檔時也會取大檔；主執行器空下來且沒有大檔排隊時，接手子執行器正在下載的大檔以多連線續傳。
/// **主執行器一律多連線下載**（帳號選項「大檔同時連線數」），子執行器一律單一連線——連線數由執行器決定，不看檔案大小。
/// 逐檔（同時傳輸數 1）時唯一的那個就是主執行器：每個檔案都以多連線下載。
struct TransferExecutor: Sendable {
    let jobID: UUID
    let source: any FileSource
    let destination: (any FileSource)?
    /// 經 Mac 中繼時的暫存資料夾（保存於 Application Support，關閉 app 後仍可續傳）
    let staging: URL
    let report: @Sendable (NodeEvent) async -> Void
    /// 單檔進度（節點 ID、已傳位元組）；高頻、由佇列合併
    let progress: @Sendable (UUID, Int64) -> Void
    /// 衝突詢問（佇列負責「套用到其餘衝突」的記憶）
    let ask: @Sendable (TransferConflict) async -> ConflictAction
    /// 同步工作的選項（rsync 節點用）
    var options: SyncOptions? = nil
    /// 雙向同步：rsync 以 `--update` 執行（不覆蓋另一邊較新的檔案）
    var twoWay = false
    /// 本執行器是否為反方向節點而對調了來源／目的（避免反方向節點再次對調）
    var isSwapped = false
    /// 主／子執行器組態（nil＝逐檔）。同時傳輸數 ≥ 2 時由佇列設定
    var lanes: ExecutorLanes? = nil
    /// 執行中的分派器（`run` 建立，整個工作共用；反方向的執行器沿用同一個）
    var dispatcher: TransferDispatcher? = nil
    /// 單檔遇到暫時性錯誤（斷線、磁碟暫時讀不到）時的重試等待（見 `TransferRetry`）
    var retry = TransferRetry.standard
    /// 使用者從這個工作移除的節點（佇列共用同一個）
    var removed = RemovedNodes()

    /// 大檔門檻：涉及的非 Mac 來源中最小者（Mac 與裝置沒有門檻 → 不分大小檔）
    private var largeThreshold: Int64? {
        [source, destination].compactMap { $0 }.filter { $0.id.kind != .mac }.compactMap(\.largeFileThreshold).min()
    }

    private func isLarge(_ node: TransferNode) -> Bool {
        guard let largeThreshold else { return false }
        return node.size >= largeThreshold
    }

    /// 反方向節點（雙向同步）用的執行器：來源與目的對調，其餘相同
    private var swapped: TransferExecutor? {
        guard let destination else { return nil }
        return TransferExecutor(jobID: jobID, source: destination, destination: source, staging: staging,
                                report: report, progress: progress, ask: ask, options: options, twoWay: twoWay, isSwapped: true,
                                lanes: lanes, dispatcher: dispatcher, retry: retry, removed: removed)
    }

    func run(_ nodes: [TransferNode]) async throws {
        guard let lanes else {
            _ = try await runLevel(nodes)
            return
        }
        // 遍歷（生產者）＋ 1 個主執行器 ＋ N−1 個子執行器，共用一個分派器
        let dispatcher = TransferDispatcher(subCount: lanes.subCount)
        let executor = { var copy = self; copy.dispatcher = dispatcher; return copy }()
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await executor.runLevel(nodes)
                    await dispatcher.finish()
                }
                group.addTask { try await executor.work(.main, dispatcher) }
                for index in 0..<lanes.subCount { group.addTask { try await executor.work(.sub(index), dispatcher) } }
                do {
                    for try await _ in group {}
                } catch {
                    // 等待中的成員不會自己醒來：先全部喚醒（拋取消），群組才能結束
                    await dispatcher.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            Task { await dispatcher.cancelAll() }
        }
    }

    /// 工作者迴圈：向分派器取檔案、執行、回報結果
    private func work(_ lane: ExecutorLane, _ dispatcher: TransferDispatcher) async throws {
        while let item = try await dispatcher.next(lane) {
            let node = item.node
            if lane == .main {
                await dispatcher.complete(item, try await runNode(node, on: .main))
                continue
            }
            // 子執行器：放在可單獨取消的工作裡跑，主執行器接手時只停這個檔案
            let task = Task { try await runNode(node, on: lane) }
            await dispatcher.started(item) { task.cancel() }
            do {
                let state = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                await dispatcher.complete(item, state)
            } catch is CancellationError where !Task.isCancelled {
                // 不是整個工作被取消，而是主執行器接手：進度已存為 partial，交出去後繼續取下一個
                guard await dispatcher.handOff(item) else { throw CancellationError() }
            }
        }
    }

    /// 一層節點的處理結果（父資料夾據此決定自己的狀態）
    struct LevelOutcome {
        /// 全部 `.done`（略過、移除也算未完成：移動時父資料夾據此保留來源）
        var allDone = true
        /// 有節點失敗（只有略過的不算，見 `makeDirectory`）
        var anyFailed = false

        mutating func add(_ state: NodeState) {
            if state != .done { allDone = false }
            if state == .failed { anyFailed = true }
        }
    }

    /// 執行同一層的節點，回傳處理結果。
    ///
    /// 逐檔時依序執行。有主／子執行器時，檔案依大小送進分派器、在背景傳，遍歷繼續往下；其他節點（資料夾、刪除、改名…）
    /// 依序在這裡執行。本層結束前等這一層送出的檔案都完成，父資料夾才判斷能否刪除來源。
    /// `parent`：這一層所屬的資料夾；它被移除時不再處理剩下的節點（之後才列出的子項不在佇列的樹裡，查不到自己）
    private func runLevel(_ nodes: [TransferNode], parent: UUID? = nil) async throws -> LevelOutcome {
        var outcome = LevelOutcome()
        let parentRemoved = { parent.map(removed.contains) ?? false }
        guard let dispatcher else {
            for node in nodes {
                try Task.checkCancellation()
                if parentRemoved() { return LevelOutcome(allDone: false) }
                outcome.add(try await runNode(node, on: .main))
            }
            return outcome
        }
        var submitted: [UUID] = []
        for node in nodes {
            try Task.checkCancellation()
            if parentRemoved() {
                outcome.allDone = false
                break
            }
            let finished = node.state == .done || node.state == .skipped
            if node.operation == .transferFile && !finished {
                submitted.append(try await dispatcher.submit(node, large: isLarge(node), handoffable: isDownloadToMac(node)))
            } else {
                outcome.add(try await runNode(node, on: .main))
            }
        }
        for id in submitted { outcome.add(try await dispatcher.result(id)) }
        return outcome
    }

    /// 這個檔案是否「從網路下載到 Mac」——只有這種才值得交給主執行器接手（上傳一律單一連線；
    /// 經 Mac 中繼的檔案在上傳階段被打斷，pCloud 等不能續傳上傳的來源會整份重傳）
    private func isDownloadToMac(_ node: TransferNode) -> Bool {
        let reversed = node.reversed == true && !isSwapped
        let from = reversed ? destination : source
        let to: (any FileSource)? = reversed ? source : destination
        guard let from, let to else { return false }
        return from.id.kind != .mac && to.id.kind == .mac && from.largeFileConnections > 1
    }

    /// 回傳節點最終狀態（父資料夾據此決定移動時能否刪除來源）
    /// `lane`：由哪個執行器處理（只影響單檔傳輸的連線數；資料夾等其他節點不分）
    private func runNode(_ node: TransferNode, on lane: ExecutorLane) async throws -> NodeState {
        if node.state == .done || node.state == .skipped || node.operation == .rejected { return node.state }
        // 使用者已從工作移除：不處理，也不回報（佇列的樹裡已沒有它）
        if removed.contains(node.id) { return .skipped }
        if node.reversed == true && !isSwapped, let swapped { return try await swapped.runNode(node, on: lane) }
        do {
            let state: NodeState
            switch node.operation {
            case .delete: state = try await delete(node)
            case .deleteTarget: state = try await deleteTarget(node)
            case .rsync: state = try await rsync(node)
            case .nativeMove: state = try await nativeMove(node)
            case .makeDirectory: state = try await makeDirectory(node)
            case .transferFile: state = try await removableTransfer(node, on: lane)
            case .rejected: state = node.state
            }
            if removed.contains(node.id) { return .skipped }
            if state != .partial, node.operation != .rsync { await report(.state(node.id, state)) }
            return state
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await report(.state(node.id, .failed, message: error.localizedDescription))
            return .failed
        }
    }

    // MARK: 各操作

    private func delete(_ node: TransferNode) async throws -> NodeState {
        await report(.state(node.id, .running))
        return try await deleteIfPresent(node.sourcePath, in: source, node: node)
    }

    /// 刪除的目的是「那裡不再有它」：刪除失敗但項目其實已不存在（排隊期間被移走、窗格清單過時）時不算失敗，
    /// 略過並註明。只在失敗後才查，正常刪除不多一次往返
    private func deleteIfPresent(_ path: String, in store: any FileSource, node: TransferNode) async throws -> NodeState {
        do {
            try await store.delete(path)
            return .done
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // stat 本身失敗（連不上等）時無法確定，照原錯誤回報；`try?` 會把「失敗」與「不存在」都壓成 nil，不能用
            let gone: Bool
            do { gone = try await store.stat(path) == nil } catch { gone = false }
            guard gone else { throw error }
            await report(.state(node.id, .skipped, message: String(localized: "Already gone (moved or deleted)")))
            return .skipped
        }
    }

    /// rsync 自己比對與傳輸；完成時把摘要寫進節點訊息（完成提示用）
    private func rsync(_ node: TransferNode) async throws -> NodeState {
        await report(.state(node.id, .running))
        let summary = try await RsyncCommand(options: options ?? SyncOptions(), update: twoWay)
            .run(from: node.sourcePath, to: node.targetPath)
        await report(.state(node.id, .done, message: summary.text))
        return .done
    }

    private func deleteTarget(_ node: TransferNode) async throws -> NodeState {
        guard let destination else { return .failed }
        await report(.state(node.id, .running))
        return try await deleteIfPresent(node.targetPath, in: destination, node: node)
    }

    private func nativeMove(_ node: TransferNode) async throws -> NodeState {
        await report(.state(node.id, .running))
        var target = node.targetPath
        if let existing = try await source.stat(target) {
            switch try await resolveConflict(node, target: target, existing: existing, allowResume: false) {
            case .skip: return .skipped
            case .overwrite: try await source.discard(target)
            case .rename:
                target = try await uniqueTarget(target, in: source)
                await report(.retarget(node.id, path: target))
            case .resume: break
            }
        }
        try await source.move(node.sourcePath, to: target)
        return .done
    }

    private func makeDirectory(_ node: TransferNode) async throws -> NodeState {
        guard let destination else { return .failed }
        await report(.state(node.id, .running))
        if let existing = try await destination.stat(node.targetPath) {
            // 資料夾同名：合併（不詢問）；同名的是檔案：無法合併
            guard existing.isDirectory else {
                await report(.state(node.id, .failed, message: String(localized: "A file with the same name exists at the destination")))
                return .failed
            }
        } else {
            try await destination.makeDirectory(at: node.targetPath)
        }
        var children = node.children ?? []
        if node.isUnexpanded {
            children = try await TransferPlanner.children(of: node, from: source)
            await report(.expand(node.id, children: children))
        }
        let level = try await runLevel(children, parent: node.id)
        if level.allDone {
            if node.deleteSourceAfter { try await source.delete(node.sourcePath) }
            return .done
        }
        // 有子項失敗：資料夾也失敗。只是略過（衝突選略過、使用者從工作移除）不算失敗——
        // 拷貝時資料夾照樣完成；移動時保留來源資料夾（避免刪掉沒搬走的檔案），資料夾標為略過並說明
        if level.anyFailed { return .failed }
        guard node.deleteSourceAfter else { return .done }
        await report(.state(node.id, .skipped, message: String(localized: "Some items were not moved; the source folder was kept")))
        return .skipped
    }

    /// 單檔傳輸放在可單獨中斷的工作裡：使用者從工作移除這個檔案時只停它（`RemovedNodes`），
    /// 傳完的部分由 `transferFile` 清掉，這裡回報「略過」讓同一層繼續處理其餘節點
    private func removableTransfer(_ node: TransferNode, on lane: ExecutorLane) async throws -> NodeState {
        let task = Task { try await transferFile(node, on: lane) }
        if !removed.register(node.id, cancel: { task.cancel() }) { task.cancel() }
        defer { removed.unregister(node.id) }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch is CancellationError where removed.contains(node.id) && !Task.isCancelled {
            return .skipped
        }
    }

    private func transferFile(_ node: TransferNode, on lane: ExecutorLane) async throws -> NodeState {
        guard let destination else { return .failed }
        var target = node.targetPath
        // 自己中斷或失敗過的（partial／running／failed）直接續傳；否則目的已有同名檔案時詢問
        let ours = node.state == .partial || node.state == .running || node.state == .failed
        if !ours, let existing = try await destination.stat(target) {
            let canResume = !existing.isDirectory && existing.size < node.size && pairResumable(destination)
            switch try await resolveConflict(node, target: target, existing: existing, allowResume: canResume) {
            case .skip: return .skipped
            case .resume: break
            case .overwrite: try await destination.discard(target)
            case .rename:
                target = try await uniqueTarget(target, in: destination)
                await report(.retarget(node.id, path: target))
            }
        }

        await report(.state(node.id, .running))
        await report(.fileStarted(node.id, lane: lane))
        let size = node.size
        let progress: @Sendable (Double) -> Void = { [sink = self.progress, id = node.id] fraction in
            sink(id, Int64(Double(size) * min(1, max(0, fraction))))
        }
        // 主執行器一律多連線（不論檔案大小）；子執行器一律單一連線
        let connections = lane == .main ? source.largeFileConnections : 1
        var attempt = 0
        while true {
            do {
                try await copyFile(node.sourcePath, to: target, size: size, destination: destination,
                                   stagingKey: node.id.uuidString, connections: connections, progress: progress)
                break
            } catch is CancellationError {
                await interrupted(node, target: target, destination: destination)
                throw CancellationError()
            } catch {
                // 排隊／暫停期間來源被移走或刪除（例如另一個移動工作）：沒有東西可傳，略過並清掉目的端的不完整內容。
                // 必須在判斷重試之前檢查——來源不見時目的端可能只報出「逾時」等看似暫時性的錯誤，會一直白白重試
                if await sourceVanished(node) {
                    try? await destination.discard(target)
                    await report(.state(node.id, .skipped, message: String(localized: "Source file no longer exists (moved or deleted)")))
                    return .skipped
                }
                guard attempt < retry.delays.count, isRetryable(error, node: node, target: target) else { throw error }
                // 暫時性錯誤：等一下再呼叫一次，各來源的續傳從已傳的部分接著做（見 TransferRetry）
                let delay = retry.delays[attempt]
                attempt += 1
                let seconds = Int(delay.components.seconds)
                await report(.state(node.id, .running, message: String(
                    localized: "Retrying in \(seconds) s (\(attempt)/\(retry.delays.count)): \(error.localizedDescription)")))
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    await interrupted(node, target: target, destination: destination)
                    throw CancellationError()
                }
            }
        }
        self.progress(node.id, size)
        if node.deleteSourceAfter { try await source.delete(node.sourcePath) }
        return .done
    }

    /// 檔案傳到一半被中斷：暫停／停止時保留不完整內容（`partial`，繼續時接著傳；停止由佇列清除）；
    /// 使用者把它從工作移除時，佇列的樹裡已沒有它，由這裡清掉目的端與經 Mac 中繼的暫存（只有這裡知道實際的目的路徑）
    private func interrupted(_ node: TransferNode, target: String, destination: any FileSource) async {
        guard removed.contains(node.id) else {
            await report(.state(node.id, .partial))
            return
        }
        // 這裡是已取消的工作，網路請求會直接以取消失敗：清除放在不受取消影響的獨立工作裡做完
        let local = staging.appendingPathComponent(node.id.uuidString)
        await Task.detached {
            try? await destination.discard(target)
            try? FileManager.default.removeItem(at: local)
        }.value
    }

    /// 傳輸失敗後確認：來源檔已不存在。Mac 來源所在的磁碟整顆不見時不算（那是磁碟沒接上，見 `isRetryable`）
    private func sourceVanished(_ node: TransferNode) async -> Bool {
        if source.id.kind == .mac, TransferRetry.volumeMissing(node.sourcePath) { return false }
        do {
            return try await source.stat(node.sourcePath) == nil
        } catch {
            return false
        }
    }

    /// 錯誤本身是暫時性的，或 Mac 端（來源或目的）所在的外接磁碟暫時不見了
    private func isRetryable(_ error: Error, node: TransferNode, target: String) -> Bool {
        if TransferRetry.isTransient(error) { return true }
        let macPaths = [source.id.kind == .mac ? node.sourcePath : nil,
                        destination?.id.kind == .mac ? target : nil].compactMap { $0 }
        return macPaths.contains(where: TransferRetry.volumeMissing)
    }

    /// 依來源組合選擇單檔傳輸路徑
    private func copyFile(_ path: String, to target: String, size: Int64, destination: any FileSource,
                          stagingKey: String, connections: Int,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        if source.id == destination.id, source.capabilities.nativeCopy {
            try await source.resumeCopy(path, to: target, totalSize: size, onProgress: progress)
        } else if source.id.kind == .mac {
            try await destination.resumeUpload(URL(fileURLWithPath: path), to: target, onProgress: progress)
        } else if destination.id.kind == .mac {
            try await source.resumeDownload(path, to: URL(fileURLWithPath: target), totalSize: size,
                                            connections: connections, onProgress: progress)
        } else {
            // 經 Mac 中繼：暫存檔以節點 ID 命名（隨佇列保存、跨啟動不變；不可用 hashValue，每次啟動不同），
            // 保存在工作的暫存資料夾，中斷後下載與上傳兩段都能續傳
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let local = staging.appendingPathComponent(stagingKey)
            try await source.resumeDownload(path, to: local, totalSize: size, connections: connections) { progress($0 * 0.5) }
            try await destination.resumeUpload(local, to: target) { progress(0.5 + $0 * 0.5) }
            try? FileManager.default.removeItem(at: local)
        }
    }

    // MARK: 衝突

    private func pairResumable(_ destination: any FileSource) -> Bool {
        if source.id == destination.id { return source.capabilities.resumable }
        if source.id.kind == .mac { return destination.capabilities.resumable }
        if destination.id.kind == .mac { return source.capabilities.resumable }
        return source.capabilities.resumable && destination.capabilities.resumable
    }

    private func resolveConflict(_ node: TransferNode, target: String, existing: FileStat,
                                 allowResume: Bool) async throws -> ConflictResolution {
        let sourceStat = (try? await source.stat(node.sourcePath))
            ?? FileStat(size: node.size, modified: nil, isDirectory: node.isDirectory)
        let conflict = TransferConflict(jobID: jobID, name: RemotePath.name(of: target), sourcePath: node.sourcePath,
                                        targetPath: target, source: sourceStat, target: existing, canResume: allowResume)
        let action = await ask(conflict)
        try Task.checkCancellation()
        return action.resolve(source: sourceStat, target: existing, canResume: allowResume)
    }

    private func uniqueTarget(_ target: String, in source: any FileSource) async throws -> String {
        let directory = RemotePath.parent(of: target)
        let names = Set(try await source.list(directory, includeHidden: true).map(\.name))
        return RemotePath.join(directory, FileName.unique(RemotePath.name(of: target), existing: names))
    }
}
