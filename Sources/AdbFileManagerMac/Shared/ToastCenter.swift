import SwiftUI

/// 畫面底部的短暫提示（原版 Toast）。一次只顯示一則，新的取代舊的。
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    private(set) var toast: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func success(_ message: String) { show(Toast(message: message, isError: false)) }

    func error(_ message: String) { show(Toast(message: message, isError: true)) }

    /// 使用者主動取消不算錯誤，不顯示
    func error(_ error: Error) {
        if error is CancellationError { return }
        self.error(error.localizedDescription)
    }

    func dismiss() {
        dismissTask?.cancel()
        toast = nil
    }

    private func show(_ toast: Toast) {
        self.toast = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.isError ? 6 : 2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

struct ToastOverlay: View {
    let center: ToastCenter

    var body: some View {
        VStack {
            Spacer()
            if let toast = center.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? .orange : .green)
                    Text(toast.message)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Button { center.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 6)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.3), value: center.toast)
        .allowsHitTesting(center.toast != nil)
    }
}
