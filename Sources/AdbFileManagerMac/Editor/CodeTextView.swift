import AppKit
import SwiftUI

/// 以 NSTextView 實作的程式碼編輯區。
///
/// 為什麼不用 SwiftUI `TextEditor`：它沒有尋找／取代列，大檔案效能也差。NSTextView
/// 內建 macOS 標準尋找列（⌘F、⌘⌥F 取代）、無限 undo/redo，正好涵蓋原版自己實作的功能。
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    let fileName: String
    var onCursorChange: (Int, Int) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = text
        SyntaxHighlighter.apply(to: textView.textStorage!, fileName: fileName)
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        // 外部改變（例如切換編碼重新解碼）才整份替換
        textView.string = text
        SyntaxHighlighter.apply(to: textView.textStorage!, fileName: fileName)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        weak var textView: NSTextView?
        private var highlightTask: Task<Void, Never>?

        init(_ parent: CodeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            // 上色延後 0.25 秒，連續輸入時不會每個字都重算整份文件
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                SyntaxHighlighter.apply(to: textView.textStorage!, fileName: self.parent.fileName)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let location = textView.selectedRange().location
            let prefix = (textView.string as NSString).substring(to: min(location, (textView.string as NSString).length))
            let lines = prefix.components(separatedBy: "\n")
            parent.onCursorChange(lines.count, (lines.last?.count ?? 0) + 1)
        }
    }
}
