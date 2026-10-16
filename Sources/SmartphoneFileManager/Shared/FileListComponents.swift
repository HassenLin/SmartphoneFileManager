import SFMCore
import SwiftUI

/// 兩個窗格共用的列表元件
struct FileNameCell: View {
    let item: FileItem

    var body: some View {
        Label {
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(item.isHidden ? .secondary : .primary)
        } icon: {
            Image(systemName: item.kind.symbolName)
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
        }
    }
}

enum FileDateFormat {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    static func string(_ date: Date?) -> String { date.map(formatter.string(from:)) ?? "" }
}

/// 窗格標題列的路徑麵包屑；點任一段跳到該層，雙擊切換成可輸入的文字框
struct PathBar: View {
    let components: [(title: String, target: String)]
    let onSelect: (String) -> Void
    let onSubmit: ((String) -> Void)?
    let fullPath: String

    @State private var editing = false
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing, let onSubmit {
                TextField("Path", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit {
                        editing = false
                        onSubmit(typed)
                    }
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, isFocused in if !isFocused { editing = false } }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                            }
                            Button(component.title) { onSelect(component.target) }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(index == components.count - 1 ? Color.accentColor.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                // 右鍵某一段：拷貝到該層為止的路徑
                                .contextMenu { copyPathButton(component.target) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard onSubmit != nil else { return }
                    typed = fullPath
                    editing = true
                }
                .help(fullPath)
                // 右鍵空白處：拷貝目前資料夾的完整路徑
                .contextMenu { copyPathButton(fullPath) }
            }
        }
        .frame(height: 24)
    }

    private func copyPathButton(_ path: String) -> some View {
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}

/// 排序選單（兩窗格共用）
struct SortMenu: View {
    @Binding var sortType: SortType

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sortType) {
                ForEach(SortType.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
    }
}

/// 放下目標的外框提示
/// 放下目標的藍框狀態。
///
/// 刻意放在獨立的 @Observable 物件、只由 `DropHighlightOverlay` 讀取：
/// 若用窗格的 @State，藍框一變整個窗格（含數百列的表格）就重算，並可能重建底層的拖放目的地 view，
/// AppKit 因而反覆送出離開／進入，在左右窗格間來回彈跳，主執行緒被重算塞滿（實測：拖曳時整個 app 卡住）。
@MainActor
@Observable
final class DropTargetState {
    private(set) var active = false

    /// 只在狀態改變時寫入，避免無謂的畫面更新
    func set(_ value: Bool) {
        if active != value { active = value }
    }
}

/// 藍框：永遠存在、只切換透明度，view 結構不變
struct DropHighlightOverlay: View {
    let state: DropTargetState

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .opacity(state.active ? 1 : 0)
            .allowsHitTesting(false)
    }
}

struct DropHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
    }
}
