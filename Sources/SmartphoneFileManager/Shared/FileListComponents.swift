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
            }
        }
        .frame(height: 24)
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
