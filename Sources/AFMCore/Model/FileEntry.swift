import Foundation

/// 本機與裝置端檔案的共同介面：排序、圖示、列表欄位只依賴這個協定，
/// 兩邊的窗格因此能共用 `SortType` 與列表元件。
public protocol FileEntry: Identifiable, Hashable, Sendable {
    var name: String { get }
    var isDirectory: Bool { get }
    /// 目錄為 0
    var size: Int64 { get }
    var modified: Date? { get }
}

public extension FileEntry {
    var kind: FileKind { isDirectory ? .folder : FileKind(fileName: name) }
    var isHidden: Bool { name.hasPrefix(".") }
    var sizeText: String { isDirectory ? "" : ByteFormat.string(size) }
}

/// 裝置端檔案（由 `stat` 輸出解析而來）。
public struct RemoteFile: FileEntry {
    /// 絕對路徑，同時作為 id（同一目錄內唯一，搜尋結果跨目錄亦唯一）
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?
    /// `ls -l` 樣式權限字串，例如 `drwxrwx--x`
    public let permissions: String

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, size: Int64, modified: Date?, permissions: String) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}

/// 本機檔案
public struct LocalFile: FileEntry {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?

    public var id: URL { url }

    public init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedNameKey])
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = values?.isDirectory ?? false
        self.size = Int64(values?.fileSize ?? 0)
        self.modified = values?.contentModificationDate
    }
}

/// 依副檔名分類，決定圖示與「開啟」的行為（編輯器／圖片預覽／安裝 APK）。
public enum FileKind: Sendable {
    case folder, archive, presentation, document, spreadsheet, apk, json, video, image, text, xml, audio, other

    public init(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "gz", "tgz", "tar", "xz", "bz2": self = .archive
        case "ppt", "pptx", "pps", "ppsx", "key": self = .presentation
        case "doc", "docx", "dot", "dotx", "pdf", "pages": self = .document
        case "xls", "xlsx", "xlsm", "csv", "numbers": self = .spreadsheet
        case "apk", "apks", "xapk": self = .apk
        case "json": self = .json
        case "mp4", "avi", "mkv", "mov", "flv", "wmv", "webm", "3gp": self = .video
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif": self = .image
        case "mp3", "wav", "ogg", "m4a", "flac", "aac", "amr", "opus": self = .audio
        case "xml", "html", "htm", "svg": self = .xml
        default:
            self = Self.textExtensions.contains(ext) ? .text : .other
        }
    }

    /// 內建編輯器可開啟的副檔名（含無副檔名的設定檔，見 `isEditable`）
    static let textExtensions: Set<String> = [
        "txt", "log", "md", "markdown", "ini", "conf", "cfg", "prop", "properties", "toml", "yaml", "yml",
        "sh", "bash", "zsh", "py", "kt", "kts", "java", "js", "jsx", "ts", "tsx", "css", "scss", "c", "h",
        "cpp", "hpp", "swift", "gradle", "sql", "rc", "csv", "srt", "lrc", "gitignore", "env",
    ]

    public var isEditableText: Bool {
        switch self {
        case .text, .json, .xml: return true
        default: return false
        }
    }

    /// SF Symbol 名稱（UI 層使用；放在 core 是為了讓分類與圖示同一處維護）
    public var symbolName: String {
        switch self {
        case .folder: return "folder.fill"
        case .archive: return "doc.zipper"
        case .presentation: return "rectangle.on.rectangle"
        case .document: return "doc.richtext"
        case .spreadsheet: return "tablecells"
        case .apk: return "shippingbox.fill"
        case .json: return "curlybraces"
        case .video: return "film"
        case .image: return "photo"
        case .text: return "doc.text"
        case .xml: return "chevron.left.forwardslash.chevron.right"
        case .audio: return "waveform"
        case .other: return "doc"
        }
    }
}

public enum ByteFormat {
    /// 與原版一致的 1024 進位顯示（`12.5 MB`）
    public static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.2f %@", value, units[unit])
            .replacingOccurrences(of: ".00 ", with: " ")
    }
}
