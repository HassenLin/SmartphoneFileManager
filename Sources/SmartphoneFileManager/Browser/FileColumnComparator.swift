import Foundation
import SFMCore

/// 表格欄位標題排序 ⇄ `SortType` 的轉接。
///
/// 排序的唯一真相仍是 `BrowserModel.sortType`（與排序選單、預設排序設定共用）；
/// 這裡只負責把「點了哪一欄、升／降冪」翻成 `SortType`，以及反過來決定標題上的排序箭頭。
/// 「類型（資料夾優先）」沒有對應欄位，此時標題不顯示箭頭。
struct FileColumnComparator: SortComparator, Hashable {
    enum Column: Hashable { case name, size, date }

    let column: Column
    var order: SortOrder = .forward

    init(_ column: Column, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    /// 由目前排序反推標題箭頭；類型排序回傳 nil
    init?(_ sortType: SortType) {
        switch sortType {
        case .nameAscending: self.init(.name)
        case .nameDescending: self.init(.name, order: .reverse)
        case .sizeAscending: self.init(.size)
        case .sizeDescending: self.init(.size, order: .reverse)
        case .dateAscending: self.init(.date)
        case .dateDescending: self.init(.date, order: .reverse)
        case .typeAscending, .typeDescending: return nil
        }
    }

    var sortType: SortType {
        switch (column, order) {
        case (.name, .forward): return .nameAscending
        case (.name, .reverse): return .nameDescending
        case (.size, .forward): return .sizeAscending
        case (.size, .reverse): return .sizeDescending
        case (.date, .forward): return .dateAscending
        case (.date, .reverse): return .dateDescending
        }
    }

    /// SortComparator 契約要求；實際排序由 `SortType.sorted` 執行，兩者規則一致
    func compare(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
        let result: ComparisonResult
        switch column {
        case .name: result = a.name.localizedStandardCompare(b.name)
        case .size: result = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
        case .date:
            let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
            result = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
