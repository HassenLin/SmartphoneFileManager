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
                                OutlineGroup(job.roots, children: \.children) { NodeRow(node: $0) }
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
                    if job.totalBytes > 0 {
                        Text("\(ByteFormat.string(job.doneBytes)) / \(ByteFormat.string(job.totalBytes))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(stateText).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary)
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

    private var icon: String {
        switch job.kind {
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        case .delete: return "trash"
        }
    }

    private var title: String {
        let count = job.items.count
        let from = app.title(for: job.source)
        switch job.kind {
        case .copy: return String(localized: "Copy \(count) item(s): \(from) → \(app.title(for: job.destination))")
        case .move: return String(localized: "Move \(count) item(s): \(from) → \(app.title(for: job.destination))")
        case .delete: return String(localized: "Delete \(count) item(s) on \(from)")
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

/// 工作樹的一個節點（資料夾或檔案）
private struct NodeRow: View {
    let node: TransferNode

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
                ProgressView(value: Double(node.transferred), total: Double(node.size)).frame(width: 120)
            }
            if !node.isDirectory {
                Text(ByteFormat.string(node.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            stateIcon.frame(width: 16)
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch node.state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .partial: Image(systemName: "pause.circle").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
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
