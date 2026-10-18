import Foundation
import Testing
@testable import SFMCore

/// 網路來源實機測試（預設略過）。以 URL 指定伺服器，空白分隔可多個：
///
///     SFM_LIVE_NET="ftp://u:p@127.0.0.1:2121 ftpes://u:p@127.0.0.1:2122 ftps://u:p@127.0.0.1:2123 \
///                   sftp://u:p@127.0.0.1:2222 http://u:p@127.0.0.1:8080/dav" \
///     SFM_LIVE_INSECURE=1 swift test --filter NetworkLive
///
/// scheme：`ftp`（純 FTP）、`ftpes`（FTPS explicit）、`ftps`（FTPS implicit）、`sftp`、`http`／`https`（WebDAV）；
/// 加 `?active=1` 用主動模式；路徑＝測試用的遠端資料夾（預設 `/`）。帳密中的特殊字元請百分比編碼。
/// `SFM_LIVE_INSECURE=1`：不驗證 TLS 憑證（本機自簽測試伺服器用）。
struct NetworkLiveTarget: CustomTestStringConvertible, Sendable {
    let account: NetworkAccount
    let password: String
    let testDescription: String

    static let all: [NetworkLiveTarget] = {
        let env = ProcessInfo.processInfo.environment
        let insecure = env["SFM_LIVE_INSECURE"] == "1"
        return (env["SFM_LIVE_NET"] ?? "").split(separator: " ").compactMap { text -> NetworkLiveTarget? in
            guard let comps = URLComponents(string: String(text)), let scheme = comps.scheme, let host = comps.host else { return nil }
            var account = NetworkAccount()
            switch scheme {
            case "ftp": account.protocol = .ftp; account.ftpSecurity = .none
            case "ftpes": account.protocol = .ftp; account.ftpSecurity = .explicit
            case "ftps": account.protocol = .ftp; account.ftpSecurity = .implicit
            case "sftp": account.protocol = .sftp
            case "http", "https": account.protocol = .webdav; account.useTLS = scheme == "https"
            default: return nil
            }
            account.host = host
            account.port = comps.port
            account.username = comps.user?.removingPercentEncoding ?? ""
            account.rootPath = comps.path.isEmpty ? "/" : comps.path
            if comps.queryItems?.contains(URLQueryItem(name: "active", value: "1")) == true { account.ftpMode = .active }
            if insecure { account.options.verifyCertificate = false }
            account.options.retries = 0
            account.options.timeoutSeconds = 15
            return NetworkLiveTarget(account: account, password: comps.password?.removingPercentEncoding ?? "",
                          testDescription: "\(scheme)://\(host):\(account.effectivePort)\(account.ftpMode == .active ? " active" : "")")
        }
    }()
}

@Suite("NetworkLive", .enabled(if: !NetworkLiveTarget.all.isEmpty))
struct NetworkLiveTests {
    @Test(arguments: NetworkLiveTarget.all)
    func roundTrip(_ target: NetworkLiveTarget) async throws {
        let source = try NetworkSourceFactory.make(target.account, options: target.account.options.resolved(defaults: .standard),
                                                   secret: target.password)
        let fm = FileManager.default
        let local = fm.temporaryDirectory.appendingPathComponent("sfm-live-\(UUID().uuidString)")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: local) }

        // 3 MiB 隨機內容（續傳測試要夠大才能切一半）
        var bytes = Data(count: 3 << 20)
        bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let original = local.appendingPathComponent("原始 檔案 [1].bin")
        try bytes.write(to: original)

        let root = RemotePath.join(target.account.normalizedRootPath, "sfm-live-\(UUID().uuidString.prefix(8)) 中文")
        try await source.makeDirectory(at: root)
        do {
            // 上傳／列表／stat
            let remote = RemotePath.join(root, "a [1]*.bin")
            try await source.upload(original, to: remote) { _ in }
            let listed = try await source.list(root, includeHidden: true)
            #expect(listed.map(\.name) == ["a [1]*.bin"])
            #expect(try await source.stat(remote)?.size == Int64(bytes.count))
            #expect(try await source.isDirectory(root))
            #expect(try await source.stat(RemotePath.join(root, "nope")) == nil)

            // 下載＋續傳下載（本機只留一半）
            let downloaded = local.appendingPathComponent("down.bin")
            try await source.download(remote, to: downloaded, expectedSize: Int64(bytes.count)) { _ in }
            #expect(try Data(contentsOf: downloaded) == bytes)
            try bytes.prefix(1 << 20).write(to: downloaded)
            try await source.resumeDownload(remote, to: downloaded, totalSize: Int64(bytes.count)) { _ in }
            #expect(try Data(contentsOf: downloaded) == bytes)

            // 續傳上傳：遠端先放前一半
            let half = local.appendingPathComponent("half.bin")
            try bytes.prefix(bytes.count / 2).write(to: half)
            let resumed = RemotePath.join(root, "resumed.bin")
            try await source.upload(half, to: resumed) { _ in }
            try await source.resumeUpload(original, to: resumed) { _ in }
            let check = local.appendingPathComponent("check.bin")
            try await source.download(resumed, to: check, expectedSize: nil) { _ in }
            #expect(try Data(contentsOf: check) == bytes)

            // 改名到子資料夾、資料夾上傳／下載
            let sub = RemotePath.join(root, "sub")
            try await source.makeDirectory(at: sub)
            try await source.move(remote, to: RemotePath.join(sub, "moved.bin"))
            #expect(try await source.exists(RemotePath.join(sub, "moved.bin")))
            #expect(try await !source.exists(remote))
            let folder = local.appendingPathComponent("folder")
            try fm.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("inner/x.txt"))
            try await source.upload(folder, to: RemotePath.join(root, "folder")) { _ in }
            let back = local.appendingPathComponent("folder-back")
            try await source.download(RemotePath.join(root, "folder"), to: back, expectedSize: nil) { _ in }
            #expect(try String(contentsOf: back.appendingPathComponent("inner/x.txt"), encoding: .utf8) == "x")

            if source.capabilities.nativeCopy {
                try await source.copy(resumed, to: RemotePath.join(root, "copied.bin"))
                #expect(try await source.stat(RemotePath.join(root, "copied.bin"))?.size == Int64(bytes.count))
            }
        } catch {
            try? await source.delete(root)
            throw error
        }
        try await source.delete(root)
        #expect(try await !source.exists(root))
    }

    @Test(arguments: NetworkLiveTarget.all)
    func wrongPasswordIsAuthenticationError(_ target: NetworkLiveTarget) async throws {
        guard target.account.protocol != .sftp || target.account.sftpAuth == .password else { return }
        let source = try NetworkSourceFactory.make(target.account, options: target.account.options.resolved(defaults: .standard),
                                                   secret: "definitely-wrong")
        await #expect {
            _ = try await source.list(target.account.normalizedRootPath, includeHidden: false)
        } throws: { error in
            if case NetworkError.authenticationFailed = error { return true }
            return false
        }
    }
}
