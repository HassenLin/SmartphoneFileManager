import Foundation

/// 把使用者選取的項目展開成工作樹（工作第一次開始執行時呼叫，結果保存於佇列）。
///
/// 規則：
/// - 刪除：每個選取項目一個 `.delete` 節點（遞迴刪除由來源負責）。
/// - 同來源移動且 `moveIsInstant`（同一檔案系統／儲存空間）：一個 `.nativeMove` 節點，不展開。
/// - 其餘（跨裝置、跨檔案系統、複製）：資料夾為 `.makeDirectory`，檔案為 `.transferFile`，
///   逐檔執行才能顯示進度、暫停與續傳。移動則在每個節點完成後刪除來源。
/// - **資料夾不在規劃時展開**（`expanded == false`）：執行到該資料夾才列出內容（`children(of:from:)`），
///   第一個檔案立刻開始傳，不像其他檔案管理器要先掃描完整棵樹、算出總量才動。代價是總量與預估時間
///   只涵蓋已掃描到的部分（UI 以 `TransferJob.isScanning` 標示）。同步例外：要比對兩邊，仍事先展開（`SyncPlanner`）。
/// - 目的已存在的同名項目**不在規劃時處理**，執行到該檔時才詢問（衝突對話框）；
///   唯一例外是同資料夾內複製（建立副本），比照 Finder 自動改名。
enum TransferPlanner {
    static func plan(_ job: TransferJob, source: any FileSource, destination: (any FileSource)?) async throws -> [TransferNode] {
        if job.kind == .delete {
            return job.items.map {
                TransferNode(name: $0.name, sourcePath: $0.path, targetPath: "", isDirectory: $0.isDirectory,
                             size: $0.size, operation: .delete)
            }
        }
        guard let destination, let rawDirectory = job.destinationDirectory else { return [] }
        if job.kind == .sync, let root = job.items.first {
            return try await SyncPlanner.plan(from: root.path, to: rawDirectory, source: source, destination: destination,
                                              options: job.syncOptions ?? SyncOptions(), twoWay: job.syncTwoWay == true)
        }
        let directory = RemotePath.normalize(rawDirectory)
        let sameSource = source.id == destination.id
        let move = job.kind == .move
        // 同資料夾複製（建立副本）時的避撞名稱
        var existing = Set(((try? await destination.list(directory, includeHidden: true)) ?? []).map(\.name))

        var roots: [TransferNode] = []
        for item in job.items {
            var target = RemotePath.join(directory, item.name)
            if sameSource {
                if RemotePath.parent(of: item.path) == directory {
                    if move {
                        roots.append(TransferNode(name: item.name, sourcePath: item.path, targetPath: target,
                                                  isDirectory: item.isDirectory, size: item.size, operation: .rejected,
                                                  state: .skipped, message: String(localized: "Already in this folder")))
                        continue
                    }
                    let unique = FileName.unique(item.name, existing: existing)
                    existing.insert(unique)
                    target = RemotePath.join(directory, unique)
                }
                if item.isDirectory && (directory == item.path || directory.hasPrefix(item.path + "/")) {
                    roots.append(TransferNode(name: item.name, sourcePath: item.path, targetPath: target,
                                              isDirectory: true, size: 0, operation: .rejected,
                                              state: .failed, message: String(localized: "Cannot put a folder inside itself")))
                    continue
                }
                if move, await source.moveIsInstant(item.path, to: target) {
                    roots.append(TransferNode(name: item.name, sourcePath: item.path, targetPath: target,
                                              isDirectory: item.isDirectory, size: item.size, operation: .nativeMove))
                    continue
                }
            }
            roots.append(node(for: item, to: target, move: move))
        }
        return roots
    }

    /// 選取項目 → 節點。資料夾只建立節點、不列出內容（見上方說明）
    static func node(for item: FileItem, to target: String, move: Bool) -> TransferNode {
        guard item.isDirectory else {
            return TransferNode(name: RemotePath.name(of: target), sourcePath: item.path, targetPath: target,
                                isDirectory: false, size: item.size, operation: .transferFile, deleteSourceAfter: move)
        }
        var node = TransferNode(name: RemotePath.name(of: target), sourcePath: item.path, targetPath: target,
                                isDirectory: true, size: 0, operation: .makeDirectory, deleteSourceAfter: move,
                                children: [])
        node.expanded = false
        return node
    }

    /// 展開一層：列出資料夾內容（含隱藏檔，依名稱排序），子資料夾同樣先不展開。檔案大小取自列表
    static func children(of directory: TransferNode, from source: any FileSource) async throws -> [TransferNode] {
        try await source.list(directory.sourcePath, includeHidden: true)
            .sorted { $0.name < $1.name }
            .map { node(for: $0, to: RemotePath.join(directory.targetPath, $0.name), move: directory.deleteSourceAfter) }
    }
}
