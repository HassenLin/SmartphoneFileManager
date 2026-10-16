import SFMCore
import SwiftUI

/// 檔案傳輸工作的協調者：可同時進行多個傳輸，各自可取消。
///
/// 進度顯示在視窗底部的非強制回應面板（`TransferPanel`），傳輸期間仍可繼續瀏覽與操作。
/// 原本以 sheet 顯示、且一次只允許一個傳輸：sheet 會擋住整個視窗直到傳輸結束，
/// 傳輸中發起的新操作也會被默默忽略。
///
/// 併發：各工作是獨立的 Task；同一台 MTP 裝置的工作由 `MTPSession` 的序列佇列自然排隊，
/// adb／afcclient 每個操作是獨立子行程，可並行。
///
/// 取消路徑：`TransferJob.cancel()` → 取消 Task → 正在 await 的 `ProcessRunner`／libmtp 進度回呼收到取消 →
/// 終止子行程／中止傳輸。不完整檔案的清理由各傳輸工作在捕捉到 `CancellationError` 時自行處理。
@MainActor
@Observable
final class TransferCenter {
    private(set) var jobs: [TransferJob] = []

    var isBusy: Bool { !jobs.isEmpty }

    /// - Parameters:
    ///   - work: 實際傳輸；以 `begin(item:index:count:)`、`progressSink()`、`transferSink()` 回報進度
    ///   - completion: 結束時呼叫（成功為 nil；取消為 `CancellationError`）
    func start(title: String,
               work: @escaping @MainActor (TransferJob) async throws -> Void,
               completion: @escaping @MainActor (Error?) -> Void) {
        let job = TransferJob(title: title)
        jobs.append(job)
        job.task = Task { [weak self, job] in
            var failure: Error?
            do {
                try await work(job)
                try Task.checkCancellation()
            } catch {
                failure = error
            }
            self?.jobs.removeAll { $0 === job }
            completion(failure)
        }
    }
}

/// 一個傳輸工作的狀態（面板中的一列）
@MainActor
@Observable
final class TransferJob: Identifiable {
    let id = UUID()
    let title: String
    private(set) var item = ""
    /// nil = 不確定進度（資料夾、或來源沒給進度）
    private(set) var fraction: Double?
    private(set) var index = 0
    private(set) var count = 1
    @ObservationIgnored fileprivate var task: Task<Void, Never>?

    init(title: String) { self.title = title }

    func cancel() { task?.cancel() }

    func begin(item: String, index: Int, count: Int) {
        self.item = item
        self.index = index
        self.count = count
        fraction = nil
    }

    /// 給背景傳輸回報進度用的 Sendable 閉包
    func progressSink() -> @Sendable (Double) -> Void {
        let coalescer = ProgressCoalescer<Double> { [weak self] in self?.fraction = $0 }
        return { coalescer.submit($0) }
    }

    /// 給 `FileTransfer.run` 用：同時回報目前項目、序號與進度
    func transferSink() -> @Sendable (FileTransfer.Progress) -> Void {
        let coalescer = ProgressCoalescer<FileTransfer.Progress> { [weak self] progress in
            guard let self else { return }
            item = progress.name
            index = progress.index
            count = progress.count
            fraction = progress.fraction
        }
        return { coalescer.submit($0) }
    }
}

/// 合併高頻進度回報：背景執行緒任意頻率 `submit`，主執行緒同一時間最多只排一個更新，
/// 套用的是最新值。libmtp 每傳一個 USB 區塊就回呼一次，大檔可達數十萬次；
/// 若每次都 `DispatchQueue.main.async`，主執行緒會被更新塞滿而卡頓。
final class ProgressCoalescer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false
    private let apply: @MainActor (Value) -> Void

    init(_ apply: @escaping @MainActor (Value) -> Void) { self.apply = apply }

    func submit(_ value: Value) {
        let shouldSchedule: Bool = lock.withLock {
            latest = value
            defer { scheduled = true }
            return !scheduled
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [self] in
            let value: Value? = lock.withLock {
                scheduled = false
                defer { latest = nil }
                return latest
            }
            if let value { MainActor.assumeIsolated { apply(value) } }
        }
    }
}

/// 把 MainActor 物件交給 Sendable 閉包；只在主執行緒解開（見呼叫端的 `assumeIsolated`）。
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// 傳輸進度面板：視窗底部、非強制回應，每個工作一列，可個別取消
struct TransferPanel: View {
    let center: TransferCenter

    var body: some View {
        if !center.jobs.isEmpty {
            VStack(spacing: 0) {
                Divider()
                ForEach(center.jobs) { job in
                    TransferRow(job: job)
                    if job.id != center.jobs.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .background(.bar)
        }
    }
}

private struct TransferRow: View {
    let job: TransferJob

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(job.title).font(.callout.weight(.medium))
                    if job.count > 1 {
                        Text("Item \(job.index + 1) of \(job.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let fraction = job.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if !job.item.isEmpty {
                    Text(job.item).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let fraction = job.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Button { job.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
