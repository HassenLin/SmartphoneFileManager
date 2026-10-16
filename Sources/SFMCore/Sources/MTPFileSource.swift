import CLibMTP
import Foundation

/// MTP 裝置的檔案來源（Android 檔案傳輸模式、電子書閱讀器、Garmin…），透過 libmtp。
///
/// 硬體／協定背景：MTP 沒有路徑，只有「儲存空間 + 物件 ID」構成的樹；一台裝置可有多個儲存空間
/// （Android：內部共用儲存空間、SD 卡）。這裡組成一棵虛擬樹：
///
///     /                          （虛擬）各儲存空間
///     ├── 內部共用儲存空間/…       → storage 0x00010001
///     └── SD 卡/…                → storage 0x00020001
///
/// 路徑 → 物件 ID 由 `MTPSession.pathCache` 快取；未命中時從上層逐層列目錄解析。
///
/// 裝置內複製／移動（不經 Mac）：
/// - 同一儲存空間內移動：`Move Object`（僅改父物件，瞬間完成）。
/// - 單一檔案 ≤ 256MB 的複製、跨儲存空間移動：`Copy Object`／`Move Object`，由裝置自行搬資料。
/// - 其餘（大檔、資料夾的複製／跨儲存空間移動）：經 Mac 暫存區中繼，有進度。
///   原因：MTP 的裝置端複製在完成前不回應、沒有進度，而 USB 交易逾時約 20～60 秒，
///   數 GB 的檔案會在裝置還在複製時就判定逾時（裝置端仍繼續寫），結果不可預期。
public struct MTPFileSource: FileSource {
    public let session: MTPSession

    public init(session: MTPSession) {
        self.session = session
    }

    public var id: SourceID { .mtp(session.serial) }
    public var homePath: String { "/" }
    public var capabilities: SourceCapabilities { SourceCapabilities(nativeCopy: true, resumable: true) }

    /// 裝置端複製／跨儲存空間移動的大小上限（見型別說明）
    static let deviceSideCopyLimit: Int64 = 256 << 20
    /// 列目錄時代表儲存空間根目錄的 parent
    private static let listRoot = UInt32(LIBMTP_FILES_AND_FOLDERS_ROOT)
    /// 建立資料夾／上傳到根目錄時的 parent（0 會讓 libmtp 改放到依檔案類型的預設資料夾）
    private static let createRoot: UInt32 = 0xFFFF_FFFF
    /// Move／Copy Object 的根目錄 parent（MTP 規格：0 = 儲存空間根目錄）
    private static let moveRoot: UInt32 = 0

    // MARK: 路徑解析（只在 session 佇列上呼叫）

    /// 虛擬根目錄 `/` 為 nil；儲存空間根目錄以 `id = listRoot` 的資料夾物件表示
    private static func resolve(_ path: String, in session: MTPSession) throws -> MTPObject? {
        let path = RemotePath.normalize(path)
        if path == "/" { return nil }
        if let cached = session.pathCache[path] { return cached }
        let parent = RemotePath.parent(of: path)
        if parent == "/" {
            try refreshStorages(session)
        } else {
            guard let folder = try resolve(parent, in: session), folder.isFolder else { throw notFound(path) }
            try cacheChildren(of: parent, folder: folder, in: session)
        }
        guard let object = session.pathCache[path] else { throw notFound(path) }
        return object
    }

    /// 儲存空間名稱：描述字串（去掉 `/`），空的給編號，重名加序號
    @discardableResult
    private static func refreshStorages(_ session: MTPSession) throws -> [(name: String, storage: MTPStorage)] {
        var used = Set<String>()
        var result: [(String, MTPStorage)] = []
        for (index, storage) in try session.storages().enumerated() {
            var base = storage.description.replacingOccurrences(of: "/", with: "∕").trimmingCharacters(in: .whitespaces)
            if base.isEmpty { base = "Storage \(index + 1)" }
            let name = FileName.unique(base, existing: used)
            used.insert(name)
            result.append((name, storage))
            session.pathCache["/\(name)"] = MTPObject(id: listRoot, parentID: 0, storageID: storage.id, name: name,
                                                      size: 0, modified: nil, isFolder: true)
        }
        return result
    }

    /// 列出並快取資料夾的直接子項（先清掉該資料夾舊的直接子項快取，避免殘留已刪除項目）
    @discardableResult
    private static func cacheChildren(of directory: String, folder: MTPObject, in session: MTPSession) throws -> [MTPObject] {
        let children = try session.children(storage: folder.storageID, parent: folder.id)
        let prefix = directory == "/" ? "/" : directory + "/"
        for key in session.pathCache.keys where key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("/") {
            session.pathCache[key] = nil
        }
        for child in children { session.pathCache[prefix + child.name] = child }
        return children
    }

    /// 刪除／移動後，移除該路徑與其下所有快取
    private static func invalidate(_ path: String, in session: MTPSession) {
        let path = RemotePath.normalize(path)
        for key in session.pathCache.keys where key == path || key.hasPrefix(path + "/") {
            session.pathCache[key] = nil
        }
    }

    private static func notFound(_ path: String) -> Error {
        AdbError.cannotOpenDirectory(path)
    }

    private static var virtualFolderError: Error {
        AdbError.invalidArgument(String(localized: "This is a virtual folder and cannot be changed"))
    }

    /// 寫入目的地的父資料夾（虛擬根目錄不能放東西）
    private static func destinationFolder(_ target: String, in session: MTPSession) throws -> MTPObject {
        guard let folder = try resolve(RemotePath.parent(of: target), in: session), folder.isFolder else {
            throw virtualFolderError
        }
        return folder
    }

    /// 實際的物件（不能是虛擬根目錄或儲存空間根目錄）
    private static func realObject(_ path: String, in session: MTPSession) throws -> MTPObject {
        guard let object = try resolve(path, in: session), object.id != listRoot else { throw virtualFolderError }
        return object
    }

    // MARK: 瀏覽

    public func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
        let directory = RemotePath.normalize(directory)
        return try await session.perform { session, _ in
            let items: [FileItem]
            if directory == "/" {
                items = try Self.refreshStorages(session).map { FileItem(path: "/\($0.name)", isDirectory: true) }
            } else {
                guard let folder = try Self.resolve(directory, in: session), folder.isFolder else {
                    throw Self.notFound(directory)
                }
                items = try Self.cacheChildren(of: directory, folder: folder, in: session).map {
                    FileItem(path: RemotePath.join(directory, $0.name), isDirectory: $0.isFolder,
                             size: $0.isFolder ? 0 : $0.size, modified: $0.modified)
                }
            }
            return includeHidden ? items : items.filter { !$0.isHidden }
        }
    }

    public func isDirectory(_ path: String) async throws -> Bool {
        try await session.perform { session, _ in
            guard let object = try? Self.resolve(path, in: session) else { return RemotePath.normalize(path) == "/" }
            return object.isFolder
        }
    }

    public func exists(_ path: String) async throws -> Bool {
        try await session.perform { session, _ in
            RemotePath.normalize(path) == "/" || (try? Self.resolve(path, in: session)) != nil
        }
    }

    // MARK: 修改

    public func makeDirectory(at path: String) async throws {
        try await session.perform { session, _ in
            let folder = try Self.destinationFolder(path, in: session)
            let name = RemotePath.name(of: path)
            try FileName.validate(name)
            let parent = folder.id == Self.listRoot ? Self.createRoot : folder.id
            let id = try session.createFolder(name, parent: parent, storage: folder.storageID)
            session.pathCache[RemotePath.normalize(path)] = MTPObject(id: id, parentID: folder.id, storageID: folder.storageID,
                                                                     name: name, size: 0, modified: Date(), isFolder: true)
        }
    }

    public func move(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let plan: MovePlan = try await session.perform { session, _ in
            let object = try Self.realObject(path, in: session)
            let folder = try Self.destinationFolder(target, in: session)
            let newName = RemotePath.name(of: target)
            try FileName.validate(newName)
            let sameParent = object.storageID == folder.storageID
                && (object.parentID == folder.id || (folder.id == Self.listRoot && object.parentID == 0))
            if sameParent {
                // 同資料夾：純改名
                if newName != object.name { try session.rename(object.id, to: newName) }
            } else if object.storageID == folder.storageID
                        || (!object.isFolder && object.size <= Self.deviceSideCopyLimit) {
                // 同儲存空間（只改父物件），或小檔跨儲存空間：裝置端 Move Object
                guard session.supports(LIBMTP_DEVICECAP_MoveObject) else { return .relay }
                let parent = folder.id == Self.listRoot ? Self.moveRoot : folder.id
                try session.moveObject(object.id, storage: folder.storageID, parent: parent)
                if newName != object.name { try session.rename(object.id, to: newName) }
            } else {
                return .relay
            }
            Self.invalidate(path, in: session)
            Self.invalidate(target, in: session)
            return .done
        }
        if plan == .relay {
            try await relay(path, to: target, deleteSource: true, onProgress: onProgress)
        }
        onProgress(1)
    }

    public func copy(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let plan: MovePlan = try await session.perform { session, _ in
            let object = try Self.realObject(path, in: session)
            let folder = try Self.destinationFolder(target, in: session)
            let newName = RemotePath.name(of: target)
            // 裝置端 Copy Object 保留原名、新物件 ID 不會回傳：只在目的資料夾沒有同名項目時使用，
            // 完成後重新列目錄即可找到新物件
            guard !object.isFolder, object.size <= Self.deviceSideCopyLimit, newName == object.name,
                  session.supports(LIBMTP_DEVICECAP_CopyObject) else { return .relay }
            let parentPath = RemotePath.parent(of: target)
            let siblings = try Self.cacheChildren(of: parentPath, folder: folder, in: session)
            guard !siblings.contains(where: { $0.name == newName }) else { return .relay }
            let parent = folder.id == Self.listRoot ? Self.moveRoot : folder.id
            try session.copyObject(object.id, storage: folder.storageID, parent: parent)
            try Self.cacheChildren(of: parentPath, folder: folder, in: session)
            return .done
        }
        if plan == .relay {
            try await relay(path, to: target, deleteSource: false, onProgress: onProgress)
        }
        onProgress(1)
    }

    private enum MovePlan: Sendable { case done, relay }

    /// 經 Mac 暫存區：下載（前半進度）→ 上傳（後半）→ 視需要刪除來源
    private func relay(_ path: String, to target: String, deleteSource: Bool,
                       onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("afm-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let local = staging.appendingPathComponent(RemotePath.name(of: path))
        try await download(path, to: local, expectedSize: nil) { onProgress($0 * 0.5) }
        try await upload(local, to: target) { onProgress(0.5 + $0 * 0.5) }
        if deleteSource { try await delete(path) }
    }

    /// 資料夾逐層刪除：MTP 規格未保證刪除資料夾會連帶刪除內容（Android 會，其他裝置不一定）
    public func delete(_ path: String) async throws {
        try await session.perform { session, _ in
            let object = try Self.realObject(path, in: session)
            try Self.deleteRecursively(object, in: session)
            Self.invalidate(path, in: session)
        }
    }

    private static func deleteRecursively(_ object: MTPObject, in session: MTPSession) throws {
        if object.isFolder {
            for child in try session.children(storage: object.storageID, parent: object.id) {
                try deleteRecursively(child, in: session)
            }
        }
        try session.deleteObject(object.id)
    }

    // MARK: 傳輸

    /// 裝置 → Mac。單檔有 libmtp 的真實進度；資料夾逐一下載（進度不確定）
    public func download(_ path: String, to localURL: URL, expectedSize: Int64?,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let progress = MTPProgress(onProgress)
        try await withTaskCancellationHandler {
            try await session.perform { session, _ in
                let object = try Self.realObject(path, in: session)
                try Self.download(object, to: localURL, in: session, progress: object.isFolder ? MTPProgress { _ in } : progress)
                if progress.cancelled { throw CancellationError() }
            }
        } onCancel: {
            progress.cancel()
        }
        onProgress(1)
    }

    private static func download(_ object: MTPObject, to localURL: URL, in session: MTPSession, progress: MTPProgress) throws {
        if object.isFolder {
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            for child in try session.children(storage: object.storageID, parent: object.id) {
                if progress.cancelled { throw CancellationError() }
                try download(child, to: localURL.appendingPathComponent(child.name), in: session, progress: progress)
            }
        } else {
            try session.getFile(object.id, to: localURL.path, progress: progress)
        }
    }

    /// Mac → 裝置。單檔有真實進度；資料夾先建立再逐一上傳。目的地同名項目會先刪除（覆寫語意，與 adb push 一致）
    public func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            throw AdbError.invalidArgument(String(localized: "Local file does not exist: \(localURL.path)"))
        }
        let progress = MTPProgress(onProgress)
        let isFolder = isDirectory.boolValue
        try await withTaskCancellationHandler {
            try await session.perform { session, _ in
                let folder = try Self.destinationFolder(path, in: session)
                let name = RemotePath.name(of: path)
                try FileName.validate(name)
                if let existing = try? Self.resolve(path, in: session), existing.id != Self.listRoot {
                    try Self.deleteRecursively(existing, in: session)
                    Self.invalidate(path, in: session)
                }
                try Self.upload(localURL, isFolder: isFolder, name: name, into: folder, in: session,
                                progress: isFolder ? MTPProgress { _ in } : progress)
                if progress.cancelled { throw CancellationError() }
                Self.invalidate(path, in: session)
            }
        } onCancel: {
            progress.cancel()
        }
        onProgress(1)
    }

    private static func upload(_ localURL: URL, isFolder: Bool, name: String, into folder: MTPObject,
                               in session: MTPSession, progress: MTPProgress) throws {
        let parent = folder.id == listRoot ? createRoot : folder.id
        guard isFolder else {
            let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
            _ = try session.sendFile(localURL.path, name: name, size: size, parent: parent,
                                     storage: folder.storageID, progress: progress)
            return
        }
        let id = try session.createFolder(name, parent: parent, storage: folder.storageID)
        let created = MTPObject(id: id, parentID: folder.id, storageID: folder.storageID, name: name,
                                size: 0, modified: nil, isFolder: true)
        let fm = FileManager.default
        for child in try fm.contentsOfDirectory(atPath: localURL.path) {
            if progress.cancelled { throw CancellationError() }
            var childIsFolder: ObjCBool = false
            let childURL = localURL.appendingPathComponent(child)
            fm.fileExists(atPath: childURL.path, isDirectory: &childIsFolder)
            try upload(childURL, isFolder: childIsFolder.boolValue, name: child, into: created, in: session, progress: progress)
        }
    }

    // MARK: 工作佇列（續傳）

    /// 續傳的分段大小：每段一個 MTP 交易，段與段之間檢查取消
    static let partialChunk: UInt32 = 4 << 20

    public func stat(_ path: String) async throws -> FileStat? {
        try await session.perform { session, _ in
            guard let object = try? Self.resolve(path, in: session) else {
                return RemotePath.normalize(path) == "/" ? FileStat(size: 0, modified: nil, isDirectory: true) : nil
            }
            return FileStat(size: object.isFolder ? 0 : object.size, modified: object.modified, isDirectory: object.isFolder)
        }
    }

    /// 同一儲存空間內 Move Object 只改父物件，瞬間完成
    public func moveIsInstant(_ path: String, to target: String) async -> Bool {
        (try? await session.perform { session, _ in
            let object = try Self.realObject(path, in: session)
            let folder = try Self.destinationFolder(target, in: session)
            return object.storageID == folder.storageID
        }) ?? false
    }

    /// 裝置 → Mac：本機已有部分內容且裝置支援 Get Partial Object 時，從本機大小接著分段讀取
    public func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let have = (try? fm.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        if have > 0, have == totalSize { return onProgress(1) }   // 已完整
        guard have > 0, have < totalSize else {                    // 沒有部分內容，或比來源大（無效）
            try? fm.removeItem(at: localURL)
            return try await download(path, to: localURL, expectedSize: totalSize, onProgress: onProgress)
        }
        let progress = MTPProgress(onProgress)
        let localPath = localURL.path
        let resumed: Bool = try await withTaskCancellationHandler {
            try await session.perform { session, _ in
                guard session.supports(LIBMTP_DEVICECAP_GetPartialObject) else { return false }
                let object = try Self.realObject(path, in: session)
                let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: localPath))
                defer { try? writer.close() }
                var offset = UInt64(have)
                try writer.seek(toOffset: offset)
                while offset < UInt64(object.size) {
                    if progress.cancelled { throw CancellationError() }
                    let chunk = try session.readPartial(object.id, offset: offset, maxBytes: Self.partialChunk)
                    guard !chunk.isEmpty else { break }
                    try writer.write(contentsOf: chunk)
                    offset += UInt64(chunk.count)
                    progress.report(Double(offset) / Double(max(object.size, 1)))
                }
                return true
            }
        } onCancel: {
            progress.cancel()
        }
        if !resumed {
            try? fm.removeItem(at: localURL)
            try await download(path, to: localURL, expectedSize: totalSize, onProgress: onProgress)
        }
        onProgress(1)
    }

    /// Mac → 裝置：遠端已有部分內容且裝置支援編輯物件（Android）時，從遠端大小接著分段寫入
    public func resumeUpload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let total = (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        let progress = MTPProgress(onProgress)
        let localPath = localURL.path
        let resumed: Bool = try await withTaskCancellationHandler {
            try await session.perform { session, _ in
                guard let object = try? Self.realObject(path, in: session), !object.isFolder,
                      object.size > 0, object.size < total,
                      session.supports(LIBMTP_DEVICECAP_EditObjects) else { return false }
                let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath))
                defer { try? reader.close() }
                var offset = UInt64(object.size)
                try reader.seek(toOffset: offset)
                try session.beginEdit(object.id)
                defer { try? session.endEdit(object.id) }
                while offset < UInt64(total) {
                    if progress.cancelled { throw CancellationError() }
                    guard let chunk = try reader.read(upToCount: Int(Self.partialChunk)), !chunk.isEmpty else { break }
                    try session.writePartial(object.id, offset: offset, data: chunk)
                    offset += UInt64(chunk.count)
                    progress.report(Double(offset) / Double(max(total, 1)))
                }
                Self.invalidate(path, in: session)
                return true
            }
        } onCancel: {
            progress.cancel()
        }
        if !resumed {
            // upload 會先刪除同名項目再整份傳送
            try await upload(localURL, to: path, onProgress: onProgress)
        }
        onProgress(1)
    }
}
