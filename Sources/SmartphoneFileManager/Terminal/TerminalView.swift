import SFMCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 終端機分頁集合。放在 AppModel 而非視窗裡，關掉視窗再打開時分頁仍在。
@MainActor
@Observable
final class TerminalStore {
    private(set) var sessions: [AdbShellSession] = []
    var selectedID: AdbShellSession.ID?

    var selected: AdbShellSession? { sessions.first { $0.id == selectedID } }

    func open(adbPath: String, serial: String) {
        let session = AdbShellSession(adbPath: adbPath, serial: serial)
        sessions.append(session)
        selectedID = session.id
    }

    func close(_ session: AdbShellSession) {
        session.close()
        sessions.removeAll { $0.id == session.id }
        if selectedID == session.id { selectedID = sessions.last?.id }
    }

    func closeAll() {
        sessions.forEach { $0.close() }
        sessions.removeAll()
        selectedID = nil
    }
}

/// 終端機視窗：多分頁，每頁一個 AdbShellSession（原版 TerminalPanel）
struct TerminalWindowView: View {
    let app: AppModel

    private var store: TerminalStore { app.terminals }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let session = store.selected {
                TerminalSessionView(session: session).id(session.id)
            } else {
                ContentUnavailableView {
                    Label("No terminal", systemImage: "terminal")
                } actions: {
                    Button("New Terminal") { _ = app.openTerminal() }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.sessions) { session in
                        HStack(spacing: 6) {
                            Image(systemName: session.mode == .shell ? "terminal.fill" : "terminal")
                            Text(session.serial).lineLimit(1)
                            Button { store.close(session) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(store.selectedID == session.id ? Color.accentColor.opacity(0.2) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedID = session.id }
                    }
                }
            }
            Button { _ = app.openTerminal() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New Terminal")
                .keyboardShortcut("t", modifiers: .command)
        }
        .padding(6)
    }
}

struct TerminalSessionView: View {
    let session: AdbShellSession
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var dropTargeted = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ConsoleTextView(text: session.output)
            Divider()
            HStack(spacing: 6) {
                Text(session.prompt)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) { recall(-1); return .handled }
                    .onKeyPress(.downArrow) { recall(1); return .handled }
                    .onKeyPress(.tab) { complete(); return .handled }
                    .disabled(session.isClosed)
                Button("Clear") { session.clear() }
                    .buttonStyle(.borderless)
                Button("Stop") { session.interrupt() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Cancel running adb commands (⌘.)")
            }
            .padding(8)
            .modifier(DropHighlight(active: dropTargeted))
            // 把本機檔案拖進輸入列 → 插入跳脫過的路徑（例如 adb push <拖進來的檔案> /sdcard/）
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                Task {
                    let paths = await providers.loadFileURLs().map { ShellText.quoteForInput($0.path) }
                    guard !paths.isEmpty else { return }
                    input += (input.isEmpty || input.hasSuffix(" ") ? "" : " ") + paths.joined(separator: " ") + " "
                }
                return true
            }
        }
        .onAppear { inputFocused = true }
    }

    private func submit() {
        let command = input
        input = ""
        historyIndex = nil
        if !command.trimmingCharacters(in: .whitespaces).isEmpty, history.last != command { history.append(command) }
        session.send(command)
    }

    private func recall(_ delta: Int) {
        guard !history.isEmpty else { return }
        let next = (historyIndex ?? history.count) + delta
        if next >= history.count {
            historyIndex = nil
            input = ""
        } else {
            historyIndex = max(0, next)
            input = history[historyIndex!]
        }
    }

    private func complete() {
        let command = input
        Task {
            let result = await session.complete(command)
            if input == command { input = result.command }
            session.showCandidates(result.candidates)
        }
    }
}

/// 唯讀、可選取的終端輸出。NSTextView 處理數十萬字元仍流暢（SwiftUI Text 會卡）。
struct ConsoleTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.backgroundColor = .textBackgroundColor
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        // 使用者正停在底部時才自動捲動，往上翻閱時不打擾
        let atBottom = scrollView.verticalScroller.map { $0.floatValue >= 0.99 } ?? true
            || scrollView.documentVisibleRect.maxY >= textView.bounds.maxY - 20
        if text.hasPrefix(textView.string) {
            textView.textStorage?.append(NSAttributedString(
                string: String(text.dropFirst(textView.string.count)),
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor]))
        } else {
            textView.string = text
        }
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }
}
