import Foundation

/// 複製／移動（剪下＋貼上）的唯一執行引擎，任意來源 → 任意來源。
///
/// 路徑選擇（每個項目）：
/// | 情況 | 做法 |
/// |---|---|
/// | 同一來源、移動 | `source.move`（mv；Android 跨檔案系統時有進度） |
/// | 同一來源、複製、支援原生複製 | `source.copy`（cp -r，不經 Mac，有進度） |
/// | 來源是 Mac | `destination.upload` |
/// | 目的是 Mac | `source.download` |
/// | 其他（Android ⇄ iPhone、Android A ⇄ B、iPhone 內複製） | 下載到 Mac 暫存區 → 上傳 → 清除暫存 |
///
/// iPhone 內複製無法避免經 Mac：AFC 協定只有 列目錄／建立／刪除／改名／讀／寫，沒有 copy。
///
/// 跨來源的「移動」= 複製成功後才刪除來源項目（失敗則保留來源，不會兩頭落空）。
/// 目的地同名時自動改名（`a 2.txt`），不覆寫；同資料夾內的移動視為不動作。
/// 取消時清除本次新建、尚未完成的目的項目。
public enum FileTransfer {
    public struct Progress: Sendable {
        public let index: Int
        public let count: Int
        public let name: String
        /// nil = 不確定
        public let fraction: Double?
    }

    public struct Failure: Sendable {
        public let name: String
        public let message: String
    }

    public struct Result: Sendable {
        /// 成功的目的完整路徑（UI 用來選取新項目）
        public var completed: [String] = []
        public var failures: [Failure] = []
        public var skipped: [String] = []
    }

    public static func run(
        items: [FileItem],
        from source: any FileSource,
        to destination: any FileSource,
        directory: String,
        move: Bool,
        report: @escaping @Sendable (Progress) -> Void
    ) async throws -> Result {
        var result = Result()
        let sameSource = source.id == destination.id
        // 目的資料夾既有名稱（避撞用）；讀不到就當作空的，交給實際寫入時報錯
        var existing = Set(((try? await destination.list(directory, includeHidden: true)) ?? []).map(\.name))

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            report(Progress(index: index, count: items.count, name: item.name, fraction: nil))

            let parent = RemotePath.parent(of: item.path)
            if sameSource {
                if move && parent == RemotePath.normalize(directory) {
                    result.skipped.append(item.name)   // 移到原處：不動作
                    continue
                }
                // 資料夾不能放進自己或自己的子資料夾
                let normalizedDirectory = RemotePath.normalize(directory)
                if item.isDirectory && (normalizedDirectory == item.path || normalizedDirectory.hasPrefix(item.path + "/")) {
                    result.failures.append(Failure(name: item.name,
                        message: String(localized: "Cannot put a folder inside itself")))
                    continue
                }
            }

            let targetName = FileName.unique(item.name, existing: existing)
            let target = RemotePath.join(directory, targetName)
            let progress: @Sendable (Double) -> Void = { fraction in
                report(Progress(index: index, count: items.count, name: item.name, fraction: fraction))
            }

            let isSameSourceMove = sameSource && move
            do {
                try await copyOne(item, from: source, to: destination, target: target,
                                  move: isSameSourceMove, sameSource: sameSource, progress: progress)
            } catch is CancellationError {
                // 取消：清掉這次新建的不完整項目（名稱保證是新的，不會刪到原有檔案）。
                // 同來源 mv 例外：目的可能是唯一的一份，絕不清除。
                // 用非結構化 Task：目前的 Task 已被取消，直接 await 會立刻被中止。
                if !isSameSourceMove {
                    _ = await Task { try? await destination.discard(target) }.value
                }
                throw CancellationError()
            } catch {
                result.failures.append(Failure(name: item.name, message: error.localizedDescription))
                continue
            }
            existing.insert(targetName)
            result.completed.append(target)

            // 跨來源移動：複製完成後才刪來源。此階段的錯誤／取消都不能動到已完成的目的項目。
            if move && !isSameSourceMove {
                do {
                    try await source.delete(item.path)
                } catch {
                    result.failures.append(Failure(name: item.name,
                        message: String(localized: "Copied, but the original could not be deleted: \(error.localizedDescription)")))
                }
            }
        }
        return result
    }

    /// 只負責「讓目的地出現一份」；同來源 move 時直接 mv。刪除來源由呼叫端處理。
    static func copyOne(_ item: FileItem, from source: any FileSource, to destination: any FileSource,
                            target: String, move: Bool, sameSource: Bool,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        if sameSource {
            if move {
                try await source.move(item.path, to: target, onProgress: progress)
                return
            }
            if source.capabilities.nativeCopy {
                try await source.copy(item.path, to: target, onProgress: progress)
                return
            }
        }

        let expected = item.isDirectory ? nil : item.size
        if source.id.kind == .mac {
            try await destination.upload(URL(fileURLWithPath: item.path), to: target, onProgress: progress)
        } else if destination.id.kind == .mac {
            try await source.download(item.path, to: URL(fileURLWithPath: target), expectedSize: expected, onProgress: progress)
        } else {
            // 經 Mac 暫存區中繼：前半段下載、後半段上傳
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("afm-stage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let local = staging.appendingPathComponent(item.name)
            try await source.download(item.path, to: local, expectedSize: expected) { progress($0 * 0.5) }
            try await destination.upload(local, to: target) { progress(0.5 + $0 * 0.5) }
        }
    }
}
