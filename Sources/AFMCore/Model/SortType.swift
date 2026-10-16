import Foundation

/// 檔案排序（對應原版 `SortType`，兩個窗格共用）。
public enum SortType: String, CaseIterable, Identifiable, Sendable {
    case typeAscending, typeDescending
    case nameAscending, nameDescending
    case dateAscending, dateDescending
    case sizeAscending, sizeDescending

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .typeAscending: return String(localized: "Type (folders first)")
        case .typeDescending: return String(localized: "Type (files first)")
        case .nameAscending: return String(localized: "Name (A–Z)")
        case .nameDescending: return String(localized: "Name (Z–A)")
        case .dateAscending: return String(localized: "Date (oldest)")
        case .dateDescending: return String(localized: "Date (newest)")
        case .sizeAscending: return String(localized: "Size (smallest)")
        case .sizeDescending: return String(localized: "Size (largest)")
        }
    }

    /// 名稱比較採 Finder 的自然排序（`file2` 排在 `file10` 前）
    public func sorted<Entry: FileEntry>(_ entries: [Entry]) -> [Entry] {
        func byName(_ a: Entry, _ b: Entry) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let distant = Date.distantPast
        switch self {
        case .typeAscending:
            return entries.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : byName($0, $1) }
        case .typeDescending:
            return entries.sorted { $0.isDirectory != $1.isDirectory ? !$0.isDirectory : byName($1, $0) }
        case .nameAscending: return entries.sorted(by: byName)
        case .nameDescending: return entries.sorted { byName($1, $0) }
        case .dateAscending: return entries.sorted { ($0.modified ?? distant) < ($1.modified ?? distant) }
        case .dateDescending: return entries.sorted { ($0.modified ?? distant) > ($1.modified ?? distant) }
        case .sizeAscending: return entries.sorted { $0.size < $1.size }
        case .sizeDescending: return entries.sorted { $0.size > $1.size }
        }
    }
}
