import Foundation
import Testing
@testable import SFMCore

/// 記憶體內的假裝置來源（模擬 Android／iPhone），用來驗證 FileTransfer 的路徑選擇與安全性。
final class FakeStore: @unchecked Sendable {
    let lock = NSLock()
    var files: [String: Data] = [:]        // 檔案路徑 → 內容
    var directories: Set<String> = ["/"]
    var log: [String] = []
    /// 檔案修改時間（沒有＝列表不帶時間）。上傳時設為「現在」，模擬裝置無法保留修改時間
    var modified: [String: Date] = [:]
    /// 同時進行中的下載數與其最大值（驗證並行傳輸上限）
    var activeDownloads = 0
    var maxActiveDownloads = 0
    /// 主執行器（多連線）的下載：同時數與每個檔案收到的連線數
    var activeLarge = 0
    var maxActiveLarge = 0
    var connections: [String: Int] = [:]
    /// 每個檔案每次下載收到的連線數（接手時會是 [1, 4]）
    var connectionHistory: [String: [Int]] = [:]
    /// 個別檔案的下載延遲（覆寫 FakeSource.delay）
    var delays: [String: Duration] = [:]
    /// 下載開始的順序（路徑、連線數）
    var startLog: [(String, Int)] = []
    /// 指定檔案接下來幾次下載要拋出的錯誤（依序取用；用完即正常下載），與每個檔案的下載嘗試次數
    var failures: [String: [Error]] = [:]
    var attempts: [String: Int] = [:]

    func with<T>(_ body: (FakeStore) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(self)
    }
}

struct FakeSource: FileSource {
    let id: SourceID
    let store: FakeStore
    var nativeCopy = true
    /// 每次複製／下載／上傳前的延遲（測試暫停用）
    var delay: Duration = .zero
    /// 同時傳輸數（模擬網路帳號的選項）
    var parallel = 1
    var maxParallelTransfers: Int { parallel }
    /// 大檔門檻與大檔連線數（模擬網路帳號的選項）
    var threshold: Int64? = nil
    var largeFileThreshold: Int64? { threshold }
    var largeFileConnections: Int { 4 }

    func resumeDownload(_ path: String, to localURL: URL, totalSize: Int64, connections: Int,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws {
        store.with { s in
            s.connections[path] = connections
            s.connectionHistory[path, default: []].append(connections)
            s.startLog.append((path, connections))
            if connections > 1 { s.activeLarge += 1; s.maxActiveLarge = max(s.maxActiveLarge, s.activeLarge) }
        }
        defer { if connections > 1 { store.with { $0.activeLarge -= 1 } } }
        try await resumeDownload(path, to: localURL, totalSize: totalSize, onProgress: onProgress)
    }
    var homePath: String { "/" }
    var capabilities: SourceCapabilities { SourceCapabilities(nativeCopy: nativeCopy) }

    func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
        store.with { s in
            let dirs = s.directories.filter { $0 != "/" && RemotePath.parent(of: $0) == directory }
                .map { FileItem(path: $0, isDirectory: true) }
            let files = s.files.filter { RemotePath.parent(of: $0.key) == directory }
                .map { FileItem(path: $0.key, isDirectory: false, size: Int64($0.value.count), modified: s.modified[$0.key]) }
            return dirs + files
        }
    }
    func isDirectory(_ path: String) async throws -> Bool { store.with { $0.directories.contains(path) } }
    func exists(_ path: String) async throws -> Bool { store.with { $0.directories.contains(path) || $0.files[path] != nil } }
    func makeDirectory(at path: String) async throws { store.with { _ = $0.directories.insert(path) } }

    func move(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        store.with { s in
            s.log.append("mv \(path) \(target)")
            Self.rebase(s, from: path, to: target, keep: false)
        }
    }
    func copy(_ path: String, to target: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await Task.sleep(for: delay)
        store.with { s in
            s.log.append("cp \(path) \(target)")
            Self.rebase(s, from: path, to: target, keep: true)
        }
    }
    func delete(_ path: String) async throws {
        store.with { s in
            s.log.append("rm \(path)")
            s.files = s.files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            s.directories = s.directories.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
    }
    func download(_ path: String, to localURL: URL, expectedSize: Int64?, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        store.with { s in
            s.activeDownloads += 1
            s.maxActiveDownloads = max(s.maxActiveDownloads, s.activeDownloads)
        }
        defer { store.with { $0.activeDownloads -= 1 } }
        let failure: Error? = store.with { s in
            s.attempts[path, default: 0] += 1
            return s.failures[path]?.isEmpty == false ? s.failures[path]!.removeFirst() : nil
        }
        if let failure { throw failure }
        try await Task.sleep(for: store.with { $0.delays[path] } ?? delay)
        let (dirs, files) = store.with { s in
            (s.directories.filter { $0 == path || $0.hasPrefix(path + "/") },
             s.files.filter { $0.key == path || $0.key.hasPrefix(path + "/") })
        }
        for dir in dirs.sorted() {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: localURL.path + dir.dropFirst(path.count)), withIntermediateDirectories: true)
        }
        for (file, data) in files {
            try data.write(to: URL(fileURLWithPath: localURL.path + file.dropFirst(path.count)))
        }
    }
    func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await Task.sleep(for: delay)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
        if isDir.boolValue {
            store.with { _ = $0.directories.insert(path) }
            for name in try FileManager.default.contentsOfDirectory(atPath: localURL.path) {
                try await upload(localURL.appendingPathComponent(name), to: RemotePath.join(path, name), onProgress: onProgress)
            }
        } else {
            let data = try Data(contentsOf: localURL)
            store.with {
                $0.files[path] = data
                if !$0.modified.isEmpty { $0.modified[path] = Date() }
            }
        }
    }

    static func rebase(_ s: FakeStore, from path: String, to target: String, keep: Bool) {
        for (file, data) in s.files where file == path || file.hasPrefix(path + "/") {
            s.files[target + file.dropFirst(path.count)] = data
            if !keep { s.files[file] = nil }
        }
        for dir in s.directories where dir == path || dir.hasPrefix(path + "/") {
            s.directories.insert(target + dir.dropFirst(path.count))
            if !keep { s.directories.remove(dir) }
        }
    }
}

@Suite("FileTransfer")
struct FileTransferTests {
    @Test func uniqueNames() {
        #expect(FileName.unique("a.txt", existing: []) == "a.txt")
        #expect(FileName.unique("a.txt", existing: ["a.txt", "a 2.txt"]) == "a 3.txt")
        #expect(FileName.unique("dir", existing: ["dir"]) == "dir 2")
    }

    @Test func iPhoneVirtualPaths() {
        typealias L = IPhoneFileSource.Location
        #expect(IPhoneFileSource.resolve("/") == .root)
        #expect(IPhoneFileSource.resolve("/Apps") == .appsRoot)
        #expect(IPhoneFileSource.resolve("/Media") == .media("/"))
        #expect(IPhoneFileSource.resolve("/Media/DCIM/100APPLE") == .media("/DCIM/100APPLE"))
        #expect(IPhoneFileSource.resolve("/Apps/com.apple.Pages") == .app("com.apple.Pages", "/Documents"))
        #expect(IPhoneFileSource.resolve("/Apps/com.apple.Pages/a b/c.txt") == .app("com.apple.Pages", "/Documents/a b/c.txt"))
        #expect(IPhoneFileSource.virtualPath(for: .app("x.y", "/Documents/z")) == "/Apps/x.y/z")
        #expect(IPhoneFileSource.virtualPath(for: .media("/DCIM")) == "/Media/DCIM")
        // 虛擬層與服務根受保護；不同服務不能原生 mv
        #expect(L.root.isProtected && L.appsRoot.isProtected && L.media("/").isProtected && L.app("a", "/Documents").isProtected)
        #expect(!L.media("/DCIM").isProtected)
        #expect(IPhoneFileSource.resolve("/x") == .invalid && L.invalid.isProtected && !L.invalid.isReal)
        #expect(L.media("/a").sameService(as: .media("/b")))
        #expect(!L.media("/a").sameService(as: .app("x", "/Documents/a")))
        #expect(!L.app("x", "/Documents").sameService(as: .app("y", "/Documents")))
    }

    @Test func parsesAppCatalog() throws {
        let xml = """
        some log line
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><array>
          <dict><key>CFBundleIdentifier</key><string>com.b</string><key>CFBundleDisplayName</key><string>Zeta</string>
                <key>UIFileSharingEnabled</key><true/></dict>
          <dict><key>CFBundleIdentifier</key><string>com.a</string><key>CFBundleName</key><string>Alpha</string>
                <key>UIFileSharingEnabled</key><true/></dict>
          <dict><key>CFBundleIdentifier</key><string>com.c</string><key>CFBundleDisplayName</key><string>NoShare</string></dict>
        </array></plist>
        """
        let apps = try IPhoneAppCatalog.parse(Data(xml.utf8))
        #expect(apps.map(\.name) == ["Alpha", "Zeta"])
        #expect(apps.map(\.bundleID) == ["com.a", "com.b"])
    }

    @Test func parsesAfcLongListing() {
        let lines = [
            "drwxr-xr-x    2 mobile mobile         64 20 Sep 2025 00:31:29 Podcasts",
            "-rw-r--r--    1 mobile mobile          6 16 Oct 2026 10:35:35 h 2.txt",
            "Error: something",
        ]
        let items = IPhoneFileSource.parseLongListing(lines, parent: "/Downloads")
        #expect(items.count == 2)
        #expect(items[0].isDirectory && items[0].path == "/Downloads/Podcasts")
        #expect(items[1].name == "h 2.txt" && items[1].size == 6 && items[1].modified != nil)
    }
}

@Suite("LocalResumableCopy")
struct LocalResumableCopyTests {
    /// 複製在 detached task 裡跑：呼叫端被取消（佇列暫停／停止）時必須跟著停，不能跑完整個檔案
    @Test func stopsWhenCallerIsCancelled() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("big.bin")
        let target = dir.appendingPathComponent("copy.bin")
        let size = LocalResumableCopy.chunkSize * 20
        try Data(count: size).write(to: source)

        let copy = Task {
            // 每塊放慢，讓取消一定發生在複製途中
            try await LocalResumableCopy.copy(from: source, to: target) { _ in usleep(30_000) }
        }
        try await Task.sleep(for: .milliseconds(100))
        copy.cancel()
        await #expect(throws: CancellationError.self) { try await copy.value }
        let written = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        #expect(written < size)
    }
}
