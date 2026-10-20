import SFMCore
import SwiftUI

/// 窗格來源的時間位移設定（來源選單「時間位移…」）。
/// 有的裝置回報 UTC、有的回報本機時間，檔案時間看起來差了幾小時時在這裡調整；
/// 影響窗格顯示、衝突的「較新」比較與同步（見 `TimeShiftedSource`）。
/// 以窗格中的一個檔案即時預覽，使用者對照裝置上看到的時間選擇，不必推想正負方向。
struct TimeOffsetSheet: View {
    let app: AppModel
    let side: PaneSide
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 0

    private var sourceID: SourceID? { app.pane(side).sourceID }
    /// 本機時區（分鐘），快速鍵用
    private var localMinutes: Int { TimeZone.current.secondsFromGMT() / 60 }
    /// 預覽用：窗格中第一個有日期的檔案，還原成裝置原本回報的時間
    private var sample: (name: String, reported: Date)? {
        guard let sourceID, let item = app.pane(side).files.first(where: { !$0.isDirectory && $0.modified != nil }),
              let shown = item.modified else { return nil }
        return (item.name, shown.addingTimeInterval(-TimeInterval(app.timeOffset(for: sourceID) * 60)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Time Offset: \(app.title(for: sourceID))").font(.headline)
            Text("Some devices report file times in UTC, others in local time. If times in this pane are off by a few hours, set an offset. It applies to the file list, conflict comparisons (newer / not newer) and sync.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Stepper(value: $minutes, in: -14 * 60...14 * 60, step: 30) {
                Text("Offset: \(Self.format(minutes))").monospacedDigit()
            }

            HStack {
                Button(Self.format(localMinutes)) { minutes = localMinutes }
                    .help("Device reports UTC: add the local time zone")
                Button(Self.format(-localMinutes)) { minutes = -localMinutes }
                    .help("Device time was read as UTC but is local: subtract the local time zone")
                Button("No Offset") { minutes = 0 }
            }
            .controlSize(.small)

            if let sample {
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Example").foregroundStyle(.secondary)
                            Text(sample.name).lineLimit(1).truncationMode(.middle)
                        }
                        GridRow {
                            Text("Reported").foregroundStyle(.secondary)
                            Text(FileDateFormat.string(sample.reported)).monospacedDigit()
                        }
                        GridRow {
                            Text("Shown").foregroundStyle(.secondary)
                            Text(FileDateFormat.string(sample.reported.addingTimeInterval(TimeInterval(minutes * 60))))
                                .monospacedDigit().bold()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let sourceID { app.setTimeOffset(minutes, for: sourceID) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { if let sourceID { minutes = app.timeOffset(for: sourceID) } }
    }

    /// `+8:00`、`-5:30`、`0:00`
    static func format(_ minutes: Int) -> String {
        let sign = minutes > 0 ? "+" : minutes < 0 ? "−" : ""
        return String(format: "%@%d:%02d", sign, abs(minutes) / 60, abs(minutes) % 60)
    }
}
