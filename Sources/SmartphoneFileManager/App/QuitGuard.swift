import AppKit
import SwiftUI

/// 還有傳輸在進行時，結束 app 前先詢問。兩個入口：
/// - 關閉主視窗（關掉就結束 app）：在視窗**關閉前**攔下（`MainWindowCloseGuard`），詢問以 sheet 附在主視窗上，
///   取消時視窗留著不動。若等到 `applicationShouldTerminate` 才問，視窗已經先消失了。
/// - ⌘Q：視窗不會先關，由 `AppDelegate.applicationShouldTerminate` 詢問。
@MainActor
enum QuitConfirmation {
    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Transfers are in progress. Quit anyway?")
        alert.informativeText = String(localized: "Running tasks are paused and can be resumed the next time you open the app.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }
}

/// 掛在主視窗內容上：找到所在的 NSWindow，把關閉前的詢問裝上去
struct MainWindowCloseGuard: NSViewRepresentable {
    /// 是否要先詢問（有執行中的傳輸）
    let needsConfirmation: @MainActor () -> Bool
    /// 使用者按「結束」
    let onConfirmQuit: @MainActor () -> Void

    func makeNSView(context: Context) -> GuardView {
        GuardView(closeGuard: WindowCloseGuard(needsConfirmation: needsConfirmation, onConfirmQuit: onConfirmQuit))
    }

    func updateNSView(_ view: GuardView, context: Context) { view.install() }

    final class GuardView: NSView {
        let closeGuard: WindowCloseGuard
        init(closeGuard: WindowCloseGuard) {
            self.closeGuard = closeGuard
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        /// SwiftUI 可能重設 delegate，每次更新都確認還是自己
        func install() {
            guard let window, window.delegate !== closeGuard else { return }
            closeGuard.original = window.delegate
            window.delegate = closeGuard
        }
    }
}

/// 包住 SwiftUI 自己的 window delegate 的轉送代理：只多實作 `windowShouldClose`，其餘訊息原樣轉給 SwiftUI
///（`responds(to:)`／`forwardingTarget(for:)`），不影響 SwiftUI 對視窗的管理。
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    private let needsConfirmation: @MainActor () -> Bool
    private let onConfirmQuit: @MainActor () -> Void

    init(needsConfirmation: @escaping @MainActor () -> Bool, onConfirmQuit: @escaping @MainActor () -> Void) {
        self.needsConfirmation = needsConfirmation
        self.onConfirmQuit = onConfirmQuit
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? { original }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard needsConfirmation() else { return original?.windowShouldClose?(sender) ?? true }
            // 先不關：詢問附在視窗上，按「結束」才結束 app（取消則什麼都不變，傳輸繼續）
            QuitConfirmation.makeAlert().beginSheetModal(for: sender) { [onConfirmQuit] response in
                if response == .alertFirstButtonReturn { MainActor.assumeIsolated { onConfirmQuit() } }
            }
            return false
        }
    }
}
