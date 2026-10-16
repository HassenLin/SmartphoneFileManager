import AFMCore
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

    let file: RemoteFile
    var text = ""
    private(set) var encoding = TextEncoding.utf8
    private(set) var phase: Phase = .loading
    private(set) var isSaving = false
    private(set) var savedText = ""
    var cursor = (line: 1, column: 1)

    @ObservationIgnored private var rawData = Data()
    @ObservationIgnored private let service: RemoteFileService
    @ObservationIgnored private let toasts: ToastCenter

    /// 超過此大小不開編輯器（NSTextView 與語法上色在數十 MB 時會明顯卡頓）
    static let maxEditableBytes: Int64 = 20 * 1024 * 1024

    init(file: RemoteFile, service: RemoteFileService, toasts: ToastCenter) {
        self.file = file
        self.service = service
        self.toasts = toasts
    }

    var isDirty: Bool { text != savedText }

    func load() {
        guard file.size <= Self.maxEditableBytes else {
            phase = .failed(String(localized: "File is too large to edit (\(ByteFormat.string(file.size)))."))
            return
        }
        phase = .loading
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("afm-edit-\(UUID().uuidString)")
        Task {
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                try await service.download(file.path, to: temp, expectedSize: nil) { _ in }
                rawData = try Data(contentsOf: temp)
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
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("afm-save-\(UUID().uuidString)")
        isSaving = true
        Task {
            defer {
                isSaving = false
                try? FileManager.default.removeItem(at: temp)
            }
            do {
                try encoded.data.write(to: temp)
                try await service.device.push(temp.path, to: file.path)
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
    let file: RemoteFile
    private(set) var image: NSImage?
    private(set) var error: String?

    init(file: RemoteFile) {
        self.file = file
    }

    func load(using service: RemoteFileService) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("afm-preview-\(UUID().uuidString)")
        Task {
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                try await service.download(file.path, to: temp, expectedSize: nil) { _ in }
                guard let image = NSImage(contentsOf: temp) else {
                    throw AdbError.unexpectedOutput(String(localized: "Unsupported image format"))
                }
                self.image = image
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
