import AppKit
import SFMCore
import SwiftUI

/// 主視窗底部的工作面板：可收合、可拖曳調整高度。
///
/// 上方是短暫的背景作業（開啟檔案、安裝 APK）；下方是工作佇列的樹狀清單：
/// 每個工作一列（進度、狀態、暫停／繼續／停止／移除），展開後到檔案層級。
struct TasksPanel: View {
    let app: AppModel
    @AppStorage("tasksPanel.expanded") private var expanded = true
    @AppStorage("tasksPanel.height") private var height = 220.0

    private var queue: TransferQueue { app.queue }

    var body: some View {
        if !queue.jobs.isEmpty || !app.transfers.jobs.isEmpty {
            VStack(spacing: 0) {
                if expanded { ResizeHandle(height: $height) } else { Divider() }
                header
                if expanded {
                    Divider()
                    List {
                        ForEach(app.transfers.jobs) { ActivityRow(job: $0) }
                        ForEach(queue.jobs) { job in
                            DisclosureGroup {
                                OutlineGroup(job.roots, children: \.children) { node in
                                    NodeRow(node: node, lane: queue.fileLanes[job.id]?[node.id]) {
                                        queue.removeNode(node.id, from: job.id)
                                    }
                                }
                            } label: {
                                JobRow(app: app, job: job)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(height: height)
                }
            }
            .background(.bar)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
            }
            .buttonStyle(.borderless)
            .help(expanded ? "Collapse" : "Expand")
            Text("Tasks").font(.callout.weight(.semibold))
            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if queue.jobs.contains(where: { $0.state == .running || $0.state == .pending }) {
                Button { queue.pauseAll() } label: { Image(systemName: "pause.fill") }.help("Pause All")
            }
            if queue.jobs.contains(where: { $0.state == .paused }) {
                Button { queue.resumeAll() } label: { Image(systemName: "play.fill") }.help("Resume All")
            }
            if queue.jobs.contains(where: \.state.isFinished) {
                Button("Clear Finished") { queue.clearFinished() }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var summary: String {
        let running = queue.jobs.filter(\.state.isActive).count + app.transfers.jobs.count
        let waiting = queue.jobs.filter { $0.state == .pending }.count
        let paused = queue.jobs.filter { $0.state == .paused }.count
        var parts: [String] = []
        if running > 0 { parts.append(String(localized: "\(running) running")) }
        if waiting > 0 { parts.append(String(localized: "\(waiting) waiting")) }
        if paused > 0 { parts.append(String(localized: "\(paused) paused")) }
        return parts.joined(separator: " · ")
    }
}

/// 一個工作的標題列
private struct JobRow: View {
    let app: AppModel
    let job: TransferJob

    private var queue: TransferQueue { app.queue }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    ProgressView(value: job.fraction).progressViewStyle(.linear).frame(maxWidth: 220)
                    Text(job.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if job.totalBytes > 0 {
                        Text("\(ByteFormat.string(job.doneBytes)) / \(ByteFormat.string(job.totalBytes))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let jobETA { Text(jobETA).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Text(stateText).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary)
                }
                if job.state.isActive {
                    ForEach(queue.activeFiles(of: job), id: \.node.id) { file in laneLine(file.node, lane: file.lane) }
                }
                if let message = job.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .pending, .running, .waitingForUser:
                Button { queue.pause(job.id) } label: { Image(systemName: "pause.circle") }.help("Pause")
            case .paused, .failed, .stopped:
                Button { queue.resume(job.id) } label: { Image(systemName: "play.circle") }
                    .help(job.state == .paused ? "Resume" : "Retry")
            case .completed:
                EmptyView()
            }
            if !job.state.isFinished || job.state == .failed {
                Button { queue.stop(job.id) } label: { Image(systemName: "stop.circle") }.help("Stop")
            }
            if !job.state.isActive {
                Button { queue.remove(job.id) } label: { Image(systemName: "xmark.circle") }.help("Remove from List")
            }
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    private var rate: TransferRate? { queue.rates[job.id] }

    /// 整個工作的預估剩餘時間。仍在掃描（資料夾尚未展開）時只涵蓋已知部分，標為「至少」
    private var jobETA: String? {
        guard job.state == .running, let seconds = rate?.secondsRemaining(job.totalBytes - job.doneBytes) else {
            return job.state == .running && job.isScanning ? String(localized: "Scanning…") : nil
        }
        let time = DurationFormat.string(seconds)
        return job.isScanning ? String(localized: "At least \(time) left (still scanning)")
                              : String(localized: "About \(time) left")
    }

    /// 每個執行器一行：執行器顏色的進度條、檔名、這個檔案自己的百分比／速率／剩餘時間（`fileRates`）。
    /// 主執行器在最上面；整個工作的總進度與總速率在上一行。重試等待中的訊息也顯示在這裡
    private func laneLine(_ file: TransferNode, lane: ExecutorLane) -> some View {
        let fraction = file.size > 0 ? min(1, Double(file.transferred) / Double(file.size)) : 0
        let rate = queue.fileRates[file.id]
        var parts = [fraction.formatted(.percent.precision(.fractionLength(0)))]
        if let speed = rate?.bytesPerSecond { parts.append("\(ByteFormat.string(Int64(speed)))/s") }
        if let seconds = rate?.secondsRemaining(file.size - file.transferred) {
            parts.append(String(localized: "\(DurationFormat.string(seconds)) left"))
        }
        return HStack(spacing: 6) {
            Text(lane.title).foregroundStyle(lane.color).frame(width: 64, alignment: .leading)
            LaneBar(fraction: fraction, color: lane.color).frame(width: 120)
            Text(file.name).lineLimit(1).truncationMode(.middle)
            Text(parts.joined(separator: " · ")).monospacedDigit()
            if let message = file.message { Text(message).foregroundStyle(.orange).lineLimit(1) }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var icon: String {
        switch job.kind {
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        case .delete: return "trash"
        case .sync: return "arrow.triangle.2.circlepath"
        }
    }

    private var title: String {
        let count = job.items.count
        let from = app.title(for: job.source)
        switch job.kind {
        case .copy: return String(localized: "Copy \(count) item(s): \(from) → \(app.title(for: job.destination))")
        case .move: return String(localized: "Move \(count) item(s): \(from) → \(app.title(for: job.destination))")
        case .delete: return String(localized: "Delete \(count) item(s) on \(from)")
        case .sync:
            let folder = RemotePath.name(of: job.items.first?.path ?? "")
            return String(localized: "Sync “\(folder)”: \(from) → \(app.title(for: job.destination))")
        }
    }

    private var stateText: String {
        switch job.state {
        case .pending: return job.message == nil ? String(localized: "Queued") : ""
        case .running: return String(localized: "Running")
        case .waitingForUser: return String(localized: "Waiting for your choice")
        case .paused: return String(localized: "Paused")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        case .stopped: return String(localized: "Stopped")
        }
    }
}

/// 工作樹的一個節點（資料夾或檔案）。傳輸中的檔案以處理它的執行器顏色顯示進度。
/// 滑鼠移到列上時出現「從工作移除」（右鍵選單也有）：不再處理這個項目，傳到一半的立即中斷
private struct NodeRow: View {
    let node: TransferNode
    let lane: ExecutorLane?
    let onRemove: () -> Void
    @State private var hovering = false

    private var removable: Bool { TransferQueue.canRemove(node) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : FileKind(fileName: node.name).symbolName)
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            if let message = node.message {
                Text(message).font(.caption).foregroundStyle(node.state == .failed ? .red : .secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if node.state == .running, node.size > 0 {
                LaneBar(fraction: Double(node.transferred) / Double(node.size), color: lane?.color ?? .accentColor)
                    .frame(width: 120)
            }
            if !node.isDirectory {
                Text(ByteFormat.string(node.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            stateIcon.frame(width: 16).help(stateHelp)
            Button(action: onRemove) { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("Remove from Task")
                .frame(width: 16)
                .opacity(hovering && removable ? 1 : 0)
                .disabled(!removable)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove from Task", action: onRemove).disabled(!removable)
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch node.state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .partial: Image(systemName: "pause.circle").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        // 略過＝跳到下一個、沒有處理（不是重試）：灰色的「下一首」圖示，與完成的綠勾、失敗的紅驚嘆號一眼區分
        case .skipped: Image(systemName: "forward.end.circle.fill").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var stateHelp: String {
        switch node.state {
        case .pending: return String(localized: "Waiting")
        case .running: return String(localized: "Running")
        case .partial: return String(localized: "Interrupted; continues from where it stopped")
        case .done: return String(localized: "Done")
        case .skipped: return String(localized: "Skipped")
        case .failed: return String(localized: "Failed")
        }
    }
}

/// 執行器的顯示名稱與顏色：主執行器藍色，子執行器依編號輪流取色
extension ExecutorLane {
    private static let subColors: [Color] = [.green, .orange, .purple, .pink, .teal, .yellow, .brown, .indigo]

    var color: Color {
        switch self {
        case .main: return .blue
        case let .sub(index): return Self.subColors[index % Self.subColors.count]
        }
    }

    var title: String {
        switch self {
        case .main: return String(localized: "Main")
        case let .sub(index): return String(localized: "Sub \(index + 1)")
        }
    }
}

/// 指定顏色的細進度條（系統 ProgressView 在 macOS 不一定套用 tint，執行器要靠顏色區分）
private struct LaneBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 5)
    }
}

/// 面板上緣的拖曳把手：上下拖曳調整高度
private struct ResizeHandle: View {
    @Binding var height: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in inside ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = start ?? height
                    start = base
                    height = min(600, max(100, base - value.translation.height))
                }
                .onEnded { _ in start = nil })
    }
}
