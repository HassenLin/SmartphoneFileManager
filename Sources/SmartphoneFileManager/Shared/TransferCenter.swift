import SFMCore
import SwiftUI

/// 檔案傳輸工作的協調者：同一時間只有一個傳輸（與原版相同），可取消。
///
/// 取消路徑：`cancel()` → 取消 Task → 正在 await 的 `ProcessRunner` 收到取消 →
/// 對 adb 子行程送 SIGTERM。不完整檔案的清理由各傳輸工作在捕捉到
/// `CancellationError` 時自行處理（見 `AppModel` 的 upload／download）。
@MainActor
@Observable
final class TransferCenter {
    struct Status {
        var title: String
        var item = ""
        /// nil = 不確定進度（目錄、或 adb 沒給進度）
        var fraction: Double?
        var index = 0
        var count = 1
    }

    private(set) var status: Status?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool { status != nil }

    /// - Parameters:
    ///   - work: 實際傳輸；以 `begin(item:index:count:)` 與 `progressSink()` 回報進度
    ///   - completion: 結束時呼叫（成功為 nil；取消為 `CancellationError`）
    func start(title: String,
               work: @escaping @MainActor (TransferCenter) async throws -> Void,
               completion: @escaping @MainActor (Error?) -> Void) {
        guard task == nil else { return }
        status = Status(title: title)
        task = Task { [weak self] in
            guard let self else { return }
            var failure: Error?
            do {
                try await work(self)
                try Task.checkCancellation()
            } catch {
                failure = error
            }
            self.status = nil
            self.task = nil
            completion(failure)
        }
    }

    func begin(item: String, index: Int, count: Int) {
        status?.item = item
        status?.index = index
        status?.count = count
        status?.fraction = nil
    }

    /// 給背景傳輸回報進度用的 Sendable 閉包。以 `DispatchQueue.main` 保持更新順序（FIFO）。
    func progressSink() -> @Sendable (Double) -> Void {
        let box = UncheckedBox(self)
        return { fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.value.status?.fraction = fraction }
            }
        }
    }

    /// 給 `FileTransfer.run` 用：同時回報目前項目、序號與進度
    func transferSink() -> @Sendable (FileTransfer.Progress) -> Void {
        let box = UncheckedBox(self)
        return { progress in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.value.status?.item = progress.name
                    box.value.status?.index = progress.index
                    box.value.status?.count = progress.count
                    box.value.status?.fraction = progress.fraction
                }
            }
        }
    }

    func cancel() { task?.cancel() }
}

/// 把 MainActor 物件交給 Sendable 閉包；只在主執行緒解開（見呼叫端的 `assumeIsolated`）。
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// 傳輸進度面板（sheet）
struct TransferProgressView: View {
    let center: TransferCenter

    var body: some View {
        if let status = center.status {
            VStack(alignment: .leading, spacing: 12) {
                Text(status.title).font(.headline)
                if status.count > 1 {
                    Text("Item \(status.index + 1) of \(status.count)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text(status.item)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let fraction = status.fraction {
                    ProgressView(value: fraction) {
                        EmptyView()
                    } currentValueLabel: {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    }
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { center.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }
}
