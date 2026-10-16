import Foundation

/// 把使用者選取的項目展開成工作樹（工作第一次開始執行時呼叫，結果保存於佇列）。
///
/// 規則：
/// - 刪除：每個選取項目一個 `.delete` 節點（遞迴刪除由來源負責）。
/// - 同來源移動且 `moveIsInstant`（同一檔案系統／儲存空間）：一個 `.nativeMove` 節點，不展開。
/// - 其餘（跨裝置、跨檔案系統、複製）：資料夾展開成 `.makeDirectory` + 子項，檔案為 `.transferFile`，
///   逐檔執行才能顯示進度、暫停與續傳。移動則在每個節點完成後刪除來源。
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
            roots.append(try await expand(item, to: target, from: source, move: move))
        }
        return roots
    }

    /// 資料夾遞迴展開（含隱藏檔）；檔案大小取自列表
    static func expand(_ item: FileItem, to target: String, from source: any FileSource, move: Bool) async throws -> TransferNode {
        guard item.isDirectory else {
            return TransferNode(name: RemotePath.name(of: target), sourcePath: item.path, targetPath: target,
                                isDirectory: false, size: item.size, operation: .transferFile, deleteSourceAfter: move)
        }
        try Task.checkCancellation()
        var children: [TransferNode] = []
        for child in try await source.list(item.path, includeHidden: true).sorted(by: { $0.name < $1.name }) {
            children.append(try await expand(child, to: RemotePath.join(target, child.name), from: source, move: move))
        }
        return TransferNode(name: RemotePath.name(of: target), sourcePath: item.path, targetPath: target,
                            isDirectory: true, size: 0, operation: .makeDirectory, deleteSourceAfter: move,
                            children: children)
    }
}
