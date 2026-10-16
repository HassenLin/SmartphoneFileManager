import SFMCore
import SwiftUI

/// 目的已有同名檔案時的處理選擇（類似 FTP 客戶端）：並列來源與目的的大小、修改日期。
/// 「續傳」只在目的比來源小、且兩端都支援續傳時提供。
struct ConflictSheet: View {
    let conflict: TransferConflict
    let queue: TransferQueue
    @State private var applyToAll = false

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

            if !conflict.canResume, conflict.target.size < conflict.source.size {
                Text("Resuming is not available for this device (iPhone transfers always restart).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Apply to all remaining conflicts in this task", isOn: $applyToAll)

            HStack {
                Button("Skip") { answer(.skip) }
                Spacer()
                Button("Keep Both") { answer(.rename) }
                Button("Overwrite") { answer(.overwrite) }
                    .keyboardShortcut(conflict.canResume ? nil : .defaultAction)
                if conflict.canResume {
                    // 與工作面板的「Resume（繼續）」分開的鍵：這裡是從目的檔大小接著傳
                    Button("Resume Transfer") { answer(.resume) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
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
}
