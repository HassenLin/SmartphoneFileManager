import CLibMTP
import Darwin
import Foundation

/// MTP 物件（檔案或資料夾）的最小描述
public struct MTPObject: Sendable, Hashable {
    public let id: UInt32
    public let parentID: UInt32
    public let storageID: UInt32
    public let name: String
    public let size: Int64
    public let modified: Date?
    public let isFolder: Bool
}

/// MTP 儲存空間（Android 的「內部共用儲存空間」、SD 卡…）
public struct MTPStorage: Sendable, Hashable {
    public let id: UInt32
    public let description: String
    public let freeBytes: Int64
}

/// 一台已開啟的 MTP 裝置。
///
/// 併發契約：libmtp 不是執行緒安全的，而且 MTP 協定本身一次只能有一個交易。
/// 因此每台裝置一個 session，所有 libmtp 呼叫一律在自己的序列 `queue` 上執行（`perform`）；
/// 大檔傳輸期間同一台裝置的其他操作（例如列目錄）會排隊等候，這是協定限制。
public final class MTPSession: @unchecked Sendable {
    public let serial: String
    public let name: String
    /// USB 位置（bus + device number），偵測時用來判斷是否為同一台、已開啟的裝置
    let location: String

    /// 只在 `queue` 上存取
    private let device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>
    private let queue: DispatchQueue
    private var released = false

    /// 路徑 → 物件快取（`MTPFileSource` 使用；session 存活期間有效），只在 `queue` 上存取
    var pathCache: [String: MTPObject] = [:]

    init(device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, location: String) {
        self.device = device
        self.location = location
        self.queue = DispatchQueue(label: "mtp.\(location)")
        let serial = Self.takeString(LIBMTP_Get_Serialnumber(device))
        let friendly = Self.takeString(LIBMTP_Get_Friendlyname(device))
        let model = Self.takeString(LIBMTP_Get_Modelname(device))
        self.serial = serial.isEmpty ? location : serial
        self.name = !friendly.isEmpty ? friendly : (!model.isEmpty ? model : "MTP \(location)")
    }

    /// 在裝置的序列佇列上執行；Task 取消時會設定 `cancel` 旗標（傳輸的進度回呼據此中止）
    func perform<T: Sendable>(_ body: @escaping @Sendable (MTPSession, UnsafeMutablePointer<LIBMTP_mtpdevice_t>) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.released else {
                    return continuation.resume(throwing: AdbError.invalidArgument(String(localized: "The MTP device was disconnected")))
                }
                continuation.resume(with: Result { try body(self, self.device) })
            }
        }
    }

    /// 裝置拔除時呼叫：在佇列上釋放，確保沒有進行中的呼叫
    func release() {
        queue.async {
            guard !self.released else { return }
            self.released = true
            LIBMTP_Release_Device(self.device)
        }
    }

    // MARK: 以下函式只能在 `perform` 內（queue 上）呼叫

    /// 讀出並清空錯誤堆疊，組成錯誤
    func failure(_ what: String) -> Error {
        var messages: [String] = []
        var entry = LIBMTP_Get_Errorstack(device)
        while let current = entry {
            if let text = current.pointee.error_text { messages.append(String(cString: text)) }
            entry = current.pointee.next
        }
        LIBMTP_Clear_Errorstack(device)
        let detail = messages.isEmpty ? "" : "：" + messages.joined(separator: "；")
        return AdbError.commandFailed(exitCode: -1, output: what + detail)
    }

    func storages() throws -> [MTPStorage] {
        guard LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) == 0 else { throw failure("MTP Get Storage") }
        var result: [MTPStorage] = []
        var node = device.pointee.storage
        while let storage = node {
            let description = storage.pointee.StorageDescription.map { String(cString: $0) } ?? ""
            result.append(MTPStorage(id: storage.pointee.id, description: description,
                                     freeBytes: Int64(clamping: storage.pointee.FreeSpaceInBytes)))
            node = storage.pointee.next
        }
        return result
    }

    /// 列出某資料夾的直接子項（`parent` 為 `LIBMTP_FILES_AND_FOLDERS_ROOT` 時列儲存空間根目錄）
    func children(storage: UInt32, parent: UInt32) throws -> [MTPObject] {
        LIBMTP_Clear_Errorstack(device)
        var result: [MTPObject] = []
        var node = LIBMTP_Get_Files_And_Folders(device, storage, parent)
        while let file = node {
            result.append(Self.object(file.pointee))
            node = file.pointee.next
            LIBMTP_destroy_file_t(file)
        }
        // 空資料夾與失敗都回傳 NULL，只能從錯誤堆疊分辨
        if result.isEmpty, LIBMTP_Get_Errorstack(device) != nil { throw failure("MTP list") }
        return result
    }

    func metadata(_ id: UInt32) throws -> MTPObject {
        guard let file = LIBMTP_Get_Filemetadata(device, id) else { throw failure("MTP Get Object Info") }
        defer { LIBMTP_destroy_file_t(file) }
        return Self.object(file.pointee)
    }

    func createFolder(_ name: String, parent: UInt32, storage: UInt32) throws -> UInt32 {
        // Create_Folder 的參數是 char *（非 const），給它一份可寫的複本
        let copy = strdup(name)
        defer { free(copy) }
        let id = LIBMTP_Create_Folder(device, copy, parent, storage)
        guard id != 0 else { throw failure("MTP Create Folder \(name)") }
        return id
    }

    func rename(_ id: UInt32, to name: String) throws {
        guard let file = LIBMTP_Get_Filemetadata(device, id) else { throw failure("MTP Get Object Info") }
        defer { LIBMTP_destroy_file_t(file) }
        guard LIBMTP_Set_File_Name(device, file, name) == 0 else { throw failure("MTP rename → \(name)") }
    }

    func moveObject(_ id: UInt32, storage: UInt32, parent: UInt32) throws {
        guard LIBMTP_Move_Object(device, id, storage, parent) == 0 else { throw failure("MTP Move Object") }
    }

    func copyObject(_ id: UInt32, storage: UInt32, parent: UInt32) throws {
        guard LIBMTP_Copy_Object(device, id, storage, parent) == 0 else { throw failure("MTP Copy Object") }
    }

    func deleteObject(_ id: UInt32) throws {
        guard LIBMTP_Delete_Object(device, id) == 0 else { throw failure("MTP Delete Object") }
    }

    func supports(_ capability: LIBMTP_devicecap_t) -> Bool {
        LIBMTP_Check_Capability(device, capability) != 0
    }

    /// 裝置 → Mac 檔案，回報進度；`progress.cancelled` 為真時中止
    func getFile(_ id: UInt32, to localPath: String, progress: MTPProgress) throws {
        let context = Unmanaged.passRetained(progress)
        defer { context.release() }
        let result = LIBMTP_Get_File_To_File(device, id, localPath, mtpProgressCallback, context.toOpaque())
        if progress.cancelled { throw CancellationError() }
        guard result == 0 else { throw failure("MTP get") }
    }

    /// Mac 檔案 → 裝置，回傳新物件 ID
    func sendFile(_ localPath: String, name: String, size: Int64, parent: UInt32, storage: UInt32,
                  progress: MTPProgress) throws -> UInt32 {
        guard let file = LIBMTP_new_file_t() else { throw failure("MTP new file") }
        defer { LIBMTP_destroy_file_t(file) }   // 連同 filename 一起釋放
        file.pointee.filename = strdup(name)
        file.pointee.filesize = UInt64(max(0, size))
        file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        file.pointee.parent_id = parent
        file.pointee.storage_id = storage
        let context = Unmanaged.passRetained(progress)
        defer { context.release() }
        let result = LIBMTP_Send_File_From_File(device, localPath, file, mtpProgressCallback, context.toOpaque())
        if progress.cancelled { throw CancellationError() }
        guard result == 0 else { throw failure("MTP send \(name)") }
        return file.pointee.item_id
    }

    // MARK: 部分物件（續傳）

    /// 自 `offset` 讀取最多 `maxBytes`（Get Partial Object，Android 為 64 位元位移版）
    func readPartial(_ id: UInt32, offset: UInt64, maxBytes: UInt32) throws -> Data {
        var buffer: UnsafeMutablePointer<UInt8>?
        var size: UInt32 = 0
        guard LIBMTP_GetPartialObject(device, id, offset, maxBytes, &buffer, &size) == 0 else {
            throw failure("MTP Get Partial Object")
        }
        defer { free(buffer) }
        return buffer.map { Data(bytes: $0, count: Int(size)) } ?? Data()
    }

    /// 在物件 `offset` 處寫入（須包在 `beginEdit`／`endEdit` 之間；Android 擴充指令）
    func writePartial(_ id: UInt32, offset: UInt64, data: Data) throws {
        var bytes = data
        let result = bytes.withUnsafeMutableBytes { raw in
            LIBMTP_SendPartialObject(device, id, offset, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(raw.count))
        }
        guard result == 0 else { throw failure("MTP Send Partial Object") }
    }

    func beginEdit(_ id: UInt32) throws {
        guard LIBMTP_BeginEditObject(device, id) == 0 else { throw failure("MTP Begin Edit Object") }
    }

    func endEdit(_ id: UInt32) throws {
        guard LIBMTP_EndEditObject(device, id) == 0 else { throw failure("MTP End Edit Object") }
    }

    // MARK: 工具

    private static func object(_ file: LIBMTP_file_t) -> MTPObject {
        MTPObject(id: file.item_id, parentID: file.parent_id, storageID: file.storage_id,
                  name: file.filename.map { String(cString: $0) } ?? "",
                  size: Int64(clamping: file.filesize),
                  modified: file.modificationdate > 0 ? Date(timeIntervalSince1970: TimeInterval(file.modificationdate)) : nil,
                  isFolder: file.filetype == LIBMTP_FILETYPE_FOLDER)
    }

    /// libmtp 回傳的字串由呼叫端負責 free
    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

/// 傳輸進度與取消旗標，經 `void *` 交給 libmtp 的 C 回呼
final class MTPProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    var cancelled: Bool { lock.withLock { isCancelled } }
    func cancel() { lock.withLock { isCancelled = true } }
}

/// libmtp 進度回呼：回傳非 0 即中止傳輸（C 函式指標不能捕捉，所有狀態經 context 傳入）
private let mtpProgressCallback: LIBMTP_progressfunc_t = { sent, total, context in
    guard let context else { return 0 }
    let progress = Unmanaged<MTPProgress>.fromOpaque(context).takeUnretainedValue()
    if total > 0 { progress.report(min(1, Double(sent) / Double(total))) }
    return progress.cancelled ? 1 : 0
}
