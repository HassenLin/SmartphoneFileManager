import Foundation

/// 執行器回報給佇列的節點事件（佇列在主執行緒套用並保存）。
/// 以 `await` 回報、套用完才繼續，確保佇列判定工作結束時所有事件都已套用；
/// 高頻的進度另走不等待、會合併的 `progress` 閉包。
enum NodeEvent: Sendable {
    case state(UUID, NodeState, message: String? = nil)
    /// 衝突選「重新命名」後的新目的路徑
    case retarget(UUID, path: String)
    /// 資料夾執行到時才列出的內容（佇列寫入樹並保存，繼續時不必重新列出）
    case expand(UUID, children: [TransferNode])
}

/// 依工作樹逐節點執行（深度優先）。不持有狀態：每次繼續都以佇列保存的樹重新進入，
/// 已完成／略過的節點直接跳過，`partial` 的節點以 `resume*` 從中斷處接著做。
///
/// 取消（暫停／停止／關閉 app）：正在傳的檔案標為 `partial` 並保留不完整內容，再往上拋 `CancellationError`；
/// 停止時由佇列負責清除這些不完整內容。其他錯誤只讓該節點失敗，繼續處理其餘節點。
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

    /// 反方向節點（雙向同步）用的執行器：來源與目的對調，其餘相同
    private var swapped: TransferExecutor? {
        guard let destination else { return nil }
        return TransferExecutor(jobID: jobID, source: destination, destination: source, staging: staging,
                                report: report, progress: progress, ask: ask, options: options, twoWay: twoWay, isSwapped: true)
    }

    func run(_ nodes: [TransferNode]) async throws {
        for node in nodes {
            try Task.checkCancellation()
            _ = try await runNode(node)
        }
    }

    /// 回傳節點最終狀態（父資料夾據此決定移動時能否刪除來源）
    private func runNode(_ node: TransferNode) async throws -> NodeState {
        if node.state == .done || node.state == .skipped || node.operation == .rejected { return node.state }
        if node.reversed == true && !isSwapped, let swapped { return try await swapped.runNode(node) }
        do {
            let state: NodeState
            switch node.operation {
            case .delete: state = try await delete(node)
            case .deleteTarget: state = try await deleteTarget(node)
            case .rsync: state = try await rsync(node)
            case .nativeMove: state = try await nativeMove(node)
            case .makeDirectory: state = try await makeDirectory(node)
            case .transferFile: state = try await transferFile(node)
            case .rejected: state = node.state
            }
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
        try await source.delete(node.sourcePath)
        return .done
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
        try await destination.delete(node.targetPath)
        return .done
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
        var allDone = true
        for child in children {
            try Task.checkCancellation()
            if try await runNode(child) != .done { allDone = false }
        }
        // 移動：子項全部完成才刪除來源資料夾（有略過或失敗的項目時保留，避免刪掉未搬走的檔案）
        if node.deleteSourceAfter {
            guard allDone else { return .failed }
            try await source.delete(node.sourcePath)
        }
        return allDone ? .done : .failed
    }

    private func transferFile(_ node: TransferNode) async throws -> NodeState {
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
        let size = node.size
        let progress: @Sendable (Double) -> Void = { [sink = self.progress, id = node.id] fraction in
            sink(id, Int64(Double(size) * min(1, max(0, fraction))))
        }
        do {
            try await copyFile(node.sourcePath, to: target, size: size, destination: destination,
                               stagingKey: node.id.uuidString, progress: progress)
        } catch is CancellationError {
            await report(.state(node.id, .partial))
            throw CancellationError()
        }
        self.progress(node.id, size)
        if node.deleteSourceAfter { try await source.delete(node.sourcePath) }
        return .done
    }

    /// 依來源組合選擇單檔傳輸路徑
    private func copyFile(_ path: String, to target: String, size: Int64, destination: any FileSource,
                          stagingKey: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        if source.id == destination.id, source.capabilities.nativeCopy {
            try await source.resumeCopy(path, to: target, totalSize: size, onProgress: progress)
        } else if source.id.kind == .mac {
            try await destination.resumeUpload(URL(fileURLWithPath: path), to: target, onProgress: progress)
        } else if destination.id.kind == .mac {
            try await source.resumeDownload(path, to: URL(fileURLWithPath: target), totalSize: size, onProgress: progress)
        } else {
            // 經 Mac 中繼：暫存檔以節點 ID 命名（隨佇列保存、跨啟動不變；不可用 hashValue，每次啟動不同），
            // 保存在工作的暫存資料夾，中斷後下載與上傳兩段都能續傳
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let local = staging.appendingPathComponent(stagingKey)
            try await source.resumeDownload(path, to: local, totalSize: size) { progress($0 * 0.5) }
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
                                 allowResume: Bool) async throws -> ConflictAction {
        let sourceStat = (try? await source.stat(node.sourcePath))
            ?? FileStat(size: node.size, modified: nil, isDirectory: node.isDirectory)
        let conflict = TransferConflict(jobID: jobID, name: RemotePath.name(of: target), sourcePath: node.sourcePath,
                                        targetPath: target, source: sourceStat, target: existing, canResume: allowResume)
        let action = await ask(conflict)
        try Task.checkCancellation()
        // 「套用到全部」選了續傳、但這個檔案不能續傳時改為覆寫（FTP 客戶端的慣例）
        return action == .resume && !allowResume ? .overwrite : action
    }

    private func uniqueTarget(_ target: String, in source: any FileSource) async throws -> String {
        let directory = RemotePath.parent(of: target)
        let names = Set(try await source.list(directory, includeHidden: true).map(\.name))
        return RemotePath.join(directory, FileName.unique(RemotePath.name(of: target), existing: names))
    }
}
