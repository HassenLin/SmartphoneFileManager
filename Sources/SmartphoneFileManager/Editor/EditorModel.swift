import SFMCore
import SwiftUI

/// 裝置端文字檔編輯（原版 CodeEditorDialog + ViewModel 的 load/save/changeEncoding）。
///
/// 與原版差異：原始位元組留在記憶體，切換編碼只需重新解碼，不必再 pull 一次。
@MainActor
@Observable
final class EditorModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let item: FileItem
    var text = ""
    private(set) var encoding = TextEncoding.utf8
    private(set) var phase: Phase = .loading
    private(set) var isSaving = false
    private(set) var savedText = ""
    var cursor = (line: 1, column: 1)

    @ObservationIgnored private var rawData = Data()
    @ObservationIgnored private let source: any FileSource
    @ObservationIgnored private let toasts: ToastCenter

    /// 超過此大小不開編輯器（NSTextView 與語法上色在數十 MB 時會明顯卡頓）
    static let maxEditableBytes: Int64 = 20 * 1024 * 1024

    init(item: FileItem, source: any FileSource, toasts: ToastCenter) {
        self.item = item
        self.source = source
        self.toasts = toasts
    }

    var isDirty: Bool { text != savedText }

    func load() {
        guard item.size <= Self.maxEditableBytes else {
            phase = .failed(String(localized: "File is too large to edit (\(ByteFormat.string(item.size)))."))
            return
        }
        phase = .loading
        Task {
            do {
                rawData = try await source.read(item.path)
                let decoded = TextCodec.decode(rawData)
                encoding = decoded.encoding
                text = decoded.text
                savedText = decoded.text
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 以指定編碼重新解讀原始位元組（會放棄未存檔的修改，UI 會先確認）
    func reinterpret(as newEncoding: TextEncoding) {
        guard let decoded = TextCodec.decode(rawData, as: newEncoding) else {
            toasts.error(String(localized: "The file cannot be decoded as \(newEncoding.name)."))
            return
        }
        encoding = newEncoding
        text = decoded
        savedText = decoded
    }

    func save() {
        guard phase == .ready, !isSaving else { return }
        let content = text
        let encoded = TextCodec.encodeLosslessly(content, preferred: encoding)
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await source.write(encoded.data, to: item.path)
                rawData = encoded.data
                encoding = encoded.encoding
                savedText = content
                toasts.success(encoded.upgraded
                    ? String(localized: "Saved as UTF-8 (the text cannot be represented in the original encoding).")
                    : String(localized: "Saved"))
            } catch {
                toasts.error(error)
            }
        }
    }
}

/// 圖片預覽（原版 ImagePreviewDialog）
@MainActor
@Observable
final class ImagePreviewModel {
    let item: FileItem
    private(set) var image: NSImage?
    private(set) var error: String?

    init(item: FileItem) {
        self.item = item
    }

    func load(from source: any FileSource) {
        Task {
            do {
                guard let image = NSImage(data: try await source.read(item.path)) else {
                    throw AdbError.unexpectedOutput(String(localized: "Unsupported image format"))
                }
                self.image = image
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
