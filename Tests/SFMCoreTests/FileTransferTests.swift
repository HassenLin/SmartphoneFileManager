import Foundation
import Testing
@testable import SFMCore

/// 記憶體內的假裝置來源（模擬 Android／iPhone），用來驗證 FileTransfer 的路徑選擇與安全性。
final class FakeStore: @unchecked Sendable {
    let lock = NSLock()
    var files: [String: Data] = [:]        // 檔案路徑 → 內容
    var directories: Set<String> = ["/"]
    var log: [String] = []

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
    var homePath: String { "/" }
    var capabilities: SourceCapabilities { SourceCapabilities(nativeCopy: nativeCopy) }

    func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
        store.with { s in
            let dirs = s.directories.filter { $0 != "/" && RemotePath.parent(of: $0) == directory }
                .map { FileItem(path: $0, isDirectory: true) }
            let files = s.files.filter { RemotePath.parent(of: $0.key) == directory }
                .map { FileItem(path: $0.key, isDirectory: false, size: Int64($0.value.count)) }
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
        try await Task.sleep(for: delay)
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
            store.with { $0.files[path] = data }
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
