import Foundation

/// 檔案來源的識別。`deviceID` 為 Android serial／iPhone UDID／MTP 序號；Mac 為空字串。
/// 同一台 Android 可同時以 adb 與 MTP 兩種來源出現（兩者序號不同）。
/// 兩個窗格可以指向同一個來源（例如同一台 Android 的兩個資料夾）。
public struct SourceID: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case mac, android, iphone, mtp }

    public let kind: Kind
    public let deviceID: String

    public init(kind: Kind, deviceID: String = "") {
        self.kind = kind
        self.deviceID = deviceID
    }

    public static let mac = SourceID(kind: .mac)
    public static func android(_ serial: String) -> SourceID { SourceID(kind: .android, deviceID: serial) }
    public static func iphone(_ udid: String) -> SourceID { SourceID(kind: .iphone, deviceID: udid) }
    public static func mtp(_ serial: String) -> SourceID { SourceID(kind: .mtp, deviceID: serial) }
}

/// 來源能力：UI 依此顯示／隱藏功能，而不是到處判斷來源型別
public struct SourceCapabilities: Sendable {
    /// chmod（Android）
    public var permissions = false
    /// 遞迴搜尋（Android `find`）
    public var search = false
    /// 同來源內原生複製（iPhone AFC 沒有 copy，需經 Mac 中繼）
    public var nativeCopy = true
    /// 刪除是移到垃圾桶（Mac），UI 文案不同
    public var deleteMovesToTrash = false
    /// 單檔可從中斷處續傳（`resumeDownload`／`resumeUpload`／`resumeCopy` 真的接續而非整份重傳）。
    /// iPhone 的 AFC 無法指定讀寫位置，為 false；衝突對話框據此決定是否提供「續傳」。
    public var resumable = false

    public init(permissions: Bool = false, search: Bool = false, nativeCopy: Bool = true,
                deleteMovesToTrash: Bool = false, resumable: Bool = false) {
        self.permissions = permissions
        self.search = search
        self.nativeCopy = nativeCopy
        self.deleteMovesToTrash = deleteMovesToTrash
        self.resumable = resumable
    }
}

/// 檔案來源的抽象介面：Mac 本機、Android（adb）、iPhone（AFC）、MTP（libmtp）四種實作。
///
/// 契約：
/// - 路徑一律為該來源內的絕對路徑；`target` 參數是**完整目的路徑**（含名稱），不是目錄。
/// - 跨來源傳輸只透過 `download`（來源 → Mac 本機檔案）與 `upload`（Mac 本機檔案 → 來源），
///   由工作佇列（`TransferExecutor`）決定是否需要 Mac 暫存區中繼。來源之間互不認識。
/// - 所有方法可被 Task 取消（底層子行程會被終止）。
public protocol FileSource: Sendable {
    var id: SourceID { get }
    /// 預設起始資料夾
    var homePath: String { get }
    var capabilities: SourceCapabilities { get }

    func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem]
    func isDirectory(_ path: String) async throws -> Bool
    func exists(_ path: String) async throws -> Bool
    func makeDirectory(at path: String) async throws
    /// 同來源內移動／改名。瞬間完成的 rename 不必回報進度；實際上要搬資料的情況
    /// （Android 內部儲存 ⇄ SD 卡、iPhone 媒體區 ⇄ App）應回報 0…1
    func move(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws
    /// 同來源內原生複製（不經 Mac），回報 0…1（`capabilities.nativeCopy == false` 時不會被呼叫）
    func copy(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws
    /// 使用者刪除（Mac 為移到垃圾桶；其他來源為永久刪除，含資料夾內容）
    func delete(_ path: String) async throws
    /// 清除傳輸失敗／取消留下的不完整檔案（一律永久刪除）
    func discard(_ path: String) async throws
    /// 來源 → Mac 本機檔案（`localURL` 為完整目的路徑）
    func download(_ path: String, to localURL: URL, expectedSize: Int64?,
                  onProgress: @escaping @Sendable (Double) -> Void) async throws
    /// Mac 本機檔案或資料夾 → 來源（`path` 為完整目的路徑）
    func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws

    // MARK: 工作佇列用（單檔、可續傳）——預設實作見 ResumableTransfer.swift

    /// 檔案資訊；不存在時為 nil（衝突對話框顯示大小與日期、續傳判斷已傳大小）
    func stat(_ path: String) async throws -> FileStat?
    /// 同來源內 `move` 是否只是改名、瞬間完成（否則佇列改為逐檔複製後刪除，才能顯示進度與續傳）
    func moveIsInstant(_ path: String, to target: String) async -> Bool
    /// 單檔 來源 → Mac：`localURL` 已有部分內容時從其大小接著下載
    func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws
    /// 單檔 Mac → 來源：目的已有部分內容時從其大小接著上傳
    func resumeUpload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws
    /// 單檔同來源內複製：目的已有部分內容時接著複製
    func resumeCopy(_ path: String, to target: String, totalSize: Int64,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws
}

public extension FileSource {
    func discard(_ path: String) async throws { try await delete(path) }

    /// 不需要進度的複製
    func copy(_ path: String, to target: String) async throws {
        try await copy(path, to: target) { _ in }
    }

    /// 不需要進度的移動（改名）
    func move(_ path: String, to target: String) async throws {
        try await move(path, to: target) { _ in }
    }

    /// 寫入新檔內容（新增檔案、編輯器存檔）：先寫 Mac 暫存檔再 upload
    func write(_ data: Data, to path: String) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("afm-write-\(UUID().uuidString)")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await upload(temp, to: path) { _ in }
    }

    /// 讀取整個檔案（編輯器、圖片預覽）
    func read(_ path: String) async throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("afm-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await download(path, to: temp, expectedSize: nil) { _ in }
        return try Data(contentsOf: temp)
    }
}

/// 檔名驗證（各來源共用）
public enum FileName {
    /// 不得含 `/`、不得為 `.`/`..`/空字串
    public static func validate(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !name.contains("/") else {
            throw AdbError.invalidArgument(String(localized: "Invalid file name: \(name)"))
        }
    }

    /// 與 Finder 相同的避撞規則：`a.txt` → `a 2.txt` → `a 3.txt`
    public static func unique(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }
}
