import SFMCore
import SwiftUI

/// 目的已有同名檔案時的處理選擇（類似 FTP 客戶端）：並列來源與目的的大小、修改日期。分兩區：
/// - 這個檔案：略過／保留兩者／覆寫／續傳；勾選「其餘衝突也這樣處理」即套用到全部。
///   「續傳」一律顯示，只在目的比來源小、且兩端都支援續傳時可按（不能按時說明原因）。
/// - 依條件：一按即套用到這個工作所有剩下的衝突（含這個檔案）——規則本來就是給多個檔案用的，
///   每個檔案依自己的大小／日期判斷（見 `ConflictAction.resolve`）。
struct ConflictSheet: View {
    let conflict: TransferConflict
    let queue: TransferQueue
    @State private var applyToAll = false

    /// 不能續傳的原因；nil＝可以續傳
    private var resumeUnavailableReason: String? {
        if conflict.target.size >= conflict.source.size {
            return String(localized: "The destination file is not smaller than the source, so there is nothing to continue.")
        }
        if !conflict.canResume {
            return String(localized: "Resuming is not available for this device (iPhone transfers always restart).")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("“\(conflict.name)” already exists at the destination", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .symbolRenderingMode(.multicolor)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Size").font(.caption).foregroundStyle(.secondary)
                    Text("Modified").font(.caption).foregroundStyle(.secondary)
                }
                row(String(localized: "Source"), conflict.source, path: conflict.sourcePath)
                row(String(localized: "Destination"), conflict.target, path: conflict.targetPath)
            }

            GroupBox("This file") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Skip") { answer(.skip) }
                        Button("Keep Both") { answer(.rename) }
                        Button("Overwrite") { answer(.overwrite) }
                            .keyboardShortcut(conflict.canResume ? nil : .defaultAction)
                        // 與工作面板的「Resume（繼續）」分開的鍵：這裡是從目的檔大小接著傳
                        Button("Resume Transfer") { answer(.resume) }
                            .keyboardShortcut(conflict.canResume ? .defaultAction : nil)
                            .disabled(!conflict.canResume)
                            .help(resumeUnavailableReason ?? String(localized: "Continue from the size of the destination file"))
                        Spacer()
                    }
                    Toggle("Do the same for all remaining conflicts in this task", isOn: $applyToAll)
                    if let reason = resumeUnavailableReason, conflict.target.size < conflict.source.size {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            GroupBox("All remaining conflicts, by rule") {
                // 兩欄排列（四個按鈕一排放不下）
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    Button("Skip Same Size, Resume Smaller") { answerAll(.resumeIfSmaller) }
                        .help("Skip files of the same size; continue a smaller destination file from where it stopped (overwrite when resuming is not possible or the destination is larger)")
                    Button("Skip If Same Size") { answerAll(.overwriteIfDifferentSize) }
                        .help("Overwrite only when the sizes differ; skip files of the same size")
                    Button("Skip If Not Newer") { answerAll(.overwriteIfNewer) }
                        .help("Overwrite only when the source is newer; skip when the destination is as new or newer")
                    Button("Skip If Same Size and Not Newer") { answerAll(.overwriteIfDifferentSizeOrNewer) }
                        .help("Overwrite when the sizes differ or the source is newer; otherwise skip")
                }
                .padding(6)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func row(_ title: String, _ stat: FileStat, path: String) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(path)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ByteFormat.string(stat.size)).monospacedDigit()
                Text("\(stat.size) bytes").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(FileDateFormat.string(stat.modified)).monospacedDigit()
        }
    }

    private func answer(_ action: ConflictAction) {
        queue.answer(conflict.id, action: action, applyToAll: applyToAll)
    }

    /// 規則一律套用到全部（含這個檔案）
    private func answerAll(_ rule: ConflictAction) {
        queue.answer(conflict.id, action: rule, applyToAll: true)
    }
}
