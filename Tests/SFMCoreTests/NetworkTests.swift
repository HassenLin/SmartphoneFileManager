import Foundation
import Testing
@testable import SFMCore

@Suite("NetworkAccount／ConnectionOptions")
struct NetworkAccountTests {
    @Test func defaultPortsFollowProtocol() {
        var account = NetworkAccount(protocol: .ftp)
        account.ftpSecurity = .explicit
        #expect(account.defaultPort == 21)
        account.ftpSecurity = .implicit
        #expect(account.defaultPort == 990)
        account.protocol = .sftp
        #expect(account.defaultPort == 22)
        account.protocol = .webdav
        account.useTLS = false
        #expect(account.defaultPort == 80)
        account.port = 5006
        #expect(account.effectivePort == 5006)
    }

    @Test func encryptionAndLabels() {
        var account = NetworkAccount(protocol: .ftp)
        account.ftpSecurity = .none
        #expect(!account.isEncrypted)
        #expect(account.protocolLabel == "FTP")
        account.ftpSecurity = .explicit
        #expect(account.isEncrypted)
        #expect(account.protocolLabel == "FTPS")
        account.protocol = .pcloud
        account.pcloudRegion = .eu
        #expect(account.protocolLabel == "pCloud EU")
        #expect(account.serverLabel == "eapi.pcloud.com")
    }

    @Test func validation() {
        var account = NetworkAccount(protocol: .webdav)
        #expect(account.validationError() != nil)
        account.host = "https://nas.local"
        #expect(account.validationError() != nil)
        account.host = "nas.local"
        #expect(account.validationError() == nil)
        account.port = 70000
        #expect(account.validationError() != nil)
        account.port = nil
        account.pinnedCertSHA256 = "AB:CD"
        #expect(account.validationError() != nil)
        #expect(NetworkAccount.normalizeFingerprint("AB:cd ef") == "abcdef")
    }

    @Test func optionsFallBackToDefaults() {
        var defaults = ConnectionOptions.Resolved()
        defaults.timeoutSeconds = 45
        defaults.ftpCharset = "Big5"
        var options = ConnectionOptions()
        #expect(!options.hasOverrides)
        options.timeoutSeconds = 10
        let resolved = options.resolved(defaults: defaults)
        #expect(resolved.timeoutSeconds == 10)
        #expect(resolved.ftpCharset == "Big5")
        #expect(options.hasOverrides)
    }

    /// 舊版／缺欄位的 JSON 仍可讀（逐欄 decodeIfPresent）
    @Test func decodesPartialJSON() throws {
        let json = #"{"accounts":[{"id":"7C6F1E2A-3E58-4C59-9C3B-5F0D7F1C2B11","protocol":"ftp","host":"h"}]}"#
        let library = try JSONDecoder().decode(NetworkAccountLibrary.self, from: Data(json.utf8))
        let account = try #require(library.accounts.first)
        #expect(account.protocol == .ftp)
        #expect(account.ftpMode == .passive)
        #expect(account.rootPath == "/")
        #expect(library.defaults == .standard)
        #expect(library.options(for: account).retries == ConnectionOptions.Resolved.standard.retries)
    }

    @Test func roundTrips() throws {
        var library = NetworkAccountLibrary()
        var account = NetworkAccount(protocol: .sftp)
        account.host = "example.com"
        account.options.ftpCharset = "GBK"
        library.accounts = [account]
        library.pcloudClientID = "abc"
        let decoded = try JSONDecoder().decode(NetworkAccountLibrary.self, from: JSONEncoder().encode(library))
        #expect(decoded == library)
    }

    @Test func sourceIDCarriesAccount() {
        let account = NetworkAccount()
        #expect(account.sourceID.kind == .network)
        #expect(account.sourceID.networkAccountID == account.id)
        #expect(SourceID.mac.networkAccountID == nil)
    }
}

@Suite("pCloud")
struct PCloudTests {
    @Test func regionHosts() {
        #expect(PCloudRegion.us.apiHost == "api.pcloud.com")
        #expect(PCloudRegion.eu.apiHost == "eapi.pcloud.com")
        #expect(PCloudRegion(locationID: "2") == .eu)
        #expect(PCloudRegion(locationID: "9") == nil)
        #expect(PCloudRegion(apiHost: "EAPI.pcloud.com") == .eu)
        #expect(PCloudRegion(apiHost: "evil.example.com") == nil)
    }

    @Test func callbackParsingValidatesState() throws {
        let line = "GET /?code=abc123&state=S1&locationid=2&hostname=eapi.pcloud.com HTTP/1.1"
        let callback = try PCloudOAuth.parseCallback(requestLine: line, expectedState: "S1")
        #expect(callback.code == "abc123")
        #expect(callback.region == .eu)
        #expect(PCloudOAuth.tokenHost(for: callback, fallback: .us) == .eu)
        #expect(throws: NetworkError.self) { try PCloudOAuth.parseCallback(requestLine: line, expectedState: "other") }
        #expect(throws: NetworkError.self) {
            try PCloudOAuth.parseCallback(requestLine: "GET /?error=access_denied&state=S1 HTTP/1.1", expectedState: "S1")
        }
    }

    /// 回呼的 hostname 若不是官方 API host，換 token 時不採用（不把 client secret 送到別處）
    @Test func tokenHostIgnoresUnknownHostname() throws {
        let line = "GET /?code=c&state=S&hostname=evil.example.com HTTP/1.1"
        let callback = try PCloudOAuth.parseCallback(requestLine: line, expectedState: "S")
        #expect(PCloudOAuth.tokenHost(for: callback, fallback: .eu) == .eu)
    }

    @Test func authorizationURL() throws {
        let url = PCloudOAuth.authorizationURL(clientID: "id1", state: "st")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.host == "my.pcloud.com")
        #expect(comps.queryItems?.contains(URLQueryItem(name: "redirect_uri", value: PCloudOAuth.redirectURI)) == true)
        #expect(comps.queryItems?.contains(URLQueryItem(name: "response_type", value: "code")) == true)
    }

    @Test func errorCodesAndDates() {
        #expect(PCloudClient.error(2094, "Invalid access_token", method: "x") == .authenticationFailed("Invalid access_token (2094)"))
        #expect(PCloudClient.error(2005, "", method: "listfolder") == .notFound("pCloud listfolder: error 2005"))
        #expect(PCloudClient.error(2004, "exists", method: "x") == .alreadyExists("exists (2004)"))
        let date = PCloudClient.parseDate("Thu, 21 Mar 2013 18:31:57 +0000")
        #expect(date == Date(timeIntervalSince1970: 1_363_890_717))
    }

    @Test func tokenKindsAndDigest() {
        let session = PCloudToken(kind: .session, value: "abc")
        #expect(session.keychainValue == "session:abc")
        #expect(PCloudToken(keychainValue: "session:abc") == session)
        #expect(PCloudToken(keychainValue: "legacy").kind == .oauth)   // 舊版存的 OAuth token 沒有前綴
        // email 不分大小寫
        #expect(PCloudLogin.passwordDigest(email: "Me@X.com", password: "pw", digest: "d")
                == PCloudLogin.passwordDigest(email: "me@x.com", password: "pw", digest: "d"))
        #expect(PCloudLogin.passwordDigest(email: "me@x.com", password: "pw", digest: "d").count == 40)
    }

    @Test func plusSignIsEncoded() {
        let client = PCloudClient(region: .eu, token: PCloudToken(kind: .oauth, value: "t"), options: .standard)
        let url = client.url("stat", ["path": "/a+b c.txt"])
        #expect(url.host == "eapi.pcloud.com")
        #expect(url.absoluteString.contains("a%2Bb%20c.txt"))
    }
}

@Suite("lftp")
struct LftpTests {
    private func account(_ proto: NetworkProtocol = .ftp) -> NetworkAccount {
        var account = NetworkAccount(protocol: proto)
        account.host = "ftp.example.com"
        account.username = "me"
        return account
    }

    @Test func quoting() {
        #expect(LftpCommand.quote(#"a "b" \c"#) == #""a \"b\" \\c""#)
        #expect(LftpCommand.quoteGlob("/g[1]*d") == #""/g\\[1\\]\\*d""#)
        #expect(LftpCommand.shellQuote("/Users/me/my key") == "'/Users/me/my key'")
    }

    @Test func passiveExplicit() {
        let command = LftpCommand(account: account(), options: .standard)
        #expect(command.url == "ftp://ftp.example.com:21")
        #expect(command.settings.contains("set ftp:passive-mode on"))
        #expect(command.settings.contains("set ftp:ssl-force yes"))
        #expect(command.settings.contains("set ssl:verify-certificate yes"))
        #expect(command.open == #"open --env-password -u "me" "ftp://ftp.example.com:21""#)
    }

    @Test func activeImplicitWithNAT() {
        var account = account()
        account.ftpSecurity = .implicit
        account.ftpMode = .active
        var options = ConnectionOptions.Resolved()
        options.activeAddress = "203.0.113.5"
        options.activePortRange = "40000-40100"
        options.verifyCertificate = false
        let command = LftpCommand(account: account, options: options)
        #expect(command.url == "ftps://ftp.example.com:990")
        #expect(command.settings.contains("set ftp:passive-mode off"))
        #expect(!command.settings.contains("set ftp:ssl-force yes"))
        #expect(command.settings.contains(#"set ftp:port-ipv4 "203.0.113.5""#))
        #expect(command.settings.contains(#"set ftp:port-range "40000-40100""#))
        #expect(command.settings.contains("set ssl:verify-certificate no"))
    }

    @Test func plainFTPDisablesTLS() {
        var account = account()
        account.ftpSecurity = .none
        let settings = LftpCommand(account: account, options: .standard).settings
        #expect(settings.contains("set ftp:ssl-allow no"))
        #expect(!settings.contains { $0.hasPrefix("set ssl:verify-certificate") })
    }

    @Test func sftpKeyAuth() {
        var account = account(.sftp)
        account.sftpAuth = .key
        account.sftpKeyPath = "/Users/me/.ssh/id_ed25519"
        account.port = 2222
        let command = LftpCommand(account: account, options: .standard)
        #expect(command.url == "sftp://ftp.example.com:2222")
        #expect(command.open == #"open -u "me," "sftp://ftp.example.com:2222""#)
        #expect(command.settings.contains { $0.hasPrefix("set sftp:connect-program") && $0.contains("-i '/Users/me/.ssh/id_ed25519'") })
        // known_hosts 路徑含空白（Application Support）：值要包雙引號，否則 ssh 會切成多個檔案
        #expect(command.settings.contains { $0.contains(#"'UserKnownHostsFile=\"\#(SFTPHostKeys.file.path)\"'"#) })
    }

    @Test func retriesAreBounded() {
        var options = ConnectionOptions.Resolved()
        options.retries = 0
        let settings = LftpCommand(account: account(), options: options).settings
        // lftp 預設 1000 次重試：一定要覆寫
        #expect(settings.contains("set net:max-retries 1"))
        #expect(settings.contains("set cmd:fail-exit yes"))
    }

    @Test func extraCommandsOnlyAllowSet() {
        let text = "set ftp:use-feat no\n!rm -rf ~\nset a b; !ls\n\n  set ftp:prefer-epsv yes"
        #expect(LftpCommand.extraSettings(text) == ["set ftp:use-feat no", "set ftp:prefer-epsv yes"])
        #expect(LftpCommand.rejectedExtraLines(text) == ["!rm -rf ~", "set a b; !ls"])
    }

    @Test func parsesListing() {
        let lines = [
            "---------- 501      0         3145728 1792325773 /big.bin",
            "d--------- 501      0              64 1792325754 /中文 資料夾/",
            "-rw-r--r-- 1 ftp ftp 12 1792325754 /dir/name with 12 34 digits.txt",
            "lrwxrwxrwx 0        0               7 1792325754 /link -> a.txt",
            "drwxr-xr-x 2 0 0 4096 Oct 18 20:16 /old style",
            "garbage line",
        ]
        let items = LftpListingParser.parse(lines)
        #expect(items.count == 5)
        #expect(items[0].path == "/big.bin" && items[0].size == 3_145_728 && !items[0].isDirectory)
        #expect(items[0].modified == Date(timeIntervalSince1970: 1_792_325_773))
        #expect(items[1].path == "/中文 資料夾" && items[1].isDirectory && items[1].size == 0)
        #expect(items[2].name == "name with 12 34 digits.txt" && items[2].size == 12)
        #expect(items[3].path == "/link")
        #expect(items[4].path == "/old style" && items[4].isDirectory && items[4].modified == nil)
    }

    @Test func classifiesErrors() {
        #expect(LftpError.classify("Login failed: 530 Authentication failed.", exitCode: 1)
                == .authenticationFailed("Login failed: 530 Authentication failed."))
        #expect(LftpError.classify("Access failed: 550 No such file or directory. (/nope)", exitCode: 1)
                == .notFound("Access failed: 550 No such file or directory. (/nope)"))
        #expect(LftpError.classify("Fatal error: max-retries exceeded (Connection refused)", exitCode: 1)
                == .unreachable("Fatal error: max-retries exceeded (Connection refused)"))
        let tls = LftpError.classify("Fatal error: Certificate verification: self-signed certificate (60:96:A0:50:83:A4:57:78:CC:DB:50:2A:69:55:CA:B9:62:7F:B7:7A)", exitCode: 1)
        #expect(tls == .untrustedCertificate(fingerprint: "60:96:A0:50:83:A4:57:78:CC:DB:50:2A:69:55:CA:B9:62:7F:B7:7A"))
    }
}

@Suite("WebDAV")
struct WebDAVTests {
    private let client = WebDAVClient(baseURL: URL(string: "https://nas.local:5006")!, username: "u", password: "p",
                                      pinnedSHA256: "", options: .standard)

    @Test func encodesPaths() {
        #expect(client.url(for: "/home/a b#?.txt").absoluteString == "https://nas.local:5006/home/a%20b%23%3F.txt")
        #expect(client.url(for: "/", directory: true).absoluteString == "https://nas.local:5006/")
        #expect(client.url(for: "/home/dir", directory: true).absoluteString == "https://nas.local:5006/home/dir/")
        // NFD 輸入 → NFC
        let nfd = "/caf\u{0065}\u{0301}"
        #expect(client.url(for: nfd).absoluteString == "https://nas.local:5006/caf%C3%A9")
    }

    @Test func decodesHrefs() {
        #expect(client.path(fromHref: "/home/a%20b/") == "/home/a b")
        #expect(client.path(fromHref: "https://nas.local:5006/home/x.txt") == "/home/x.txt")
        #expect(client.path(fromHref: "/") == "/")
    }

    /// 移植自 nas_webdav 的 MultistatusParser 測試：多個 propstat 只採用 200 的那個
    @Test func parsesMultistatus() {
        let xml = """
        <?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/home/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/home/a.txt</D:href><D:propstat><D:prop><D:getcontentlength>12</D:getcontentlength>
        <D:getlastmodified>Tue, 15 Nov 1994 12:45:26 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        <D:propstat><D:prop><D:getcontentlength>999</D:getcontentlength></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
        </D:response></D:multistatus>
        """
        let responses = MultistatusParser.parse(Data(xml.utf8))
        #expect(responses.count == 2)
        #expect(responses[0].isCollection)
        #expect(responses[1].contentLength == 12)
        #expect(responses[1].lastModified == Date(timeIntervalSince1970: 784_903_526))
    }

    @Test func httpErrors() {
        #expect(WebDAVClient.httpError(401, what: "x") == .authenticationFailed("HTTP 401"))
        #expect(WebDAVClient.httpError(404, what: "GET /a") == .notFound("GET /a"))
        #expect(WebDAVClient.httpError(412, what: "MOVE /a") == .alreadyExists("MOVE /a"))
    }
}

/// 大檔多連線下載：分區塊、續傳、從單一連線部分檔接續；lftp pget 狀態檔；相關選項
@Suite("Segmented download")
struct SegmentedDownloadTests {
    let block = Int(SegmentedDownload.blockSize)

    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sfm-seg-\(UUID().uuidString).bin")
    }

    /// 記錄被抓的區塊起點
    final class Fetched: @unchecked Sendable {
        let lock = NSLock()
        var starts: [Int64] = []
        func add(_ start: Int64) { lock.withLock { starts.append(start) } }
    }

    @Test func downloadsAllBlocksInParallelAndCleansState() async throws {
        let content = Data((0..<(block * 2 + 1234)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let fetched = Fetched()
        try await SegmentedDownload.run(to: url, totalSize: Int64(content.count), connections: 3, onProgress: { _ in }) { range in
            fetched.add(range.lowerBound)
            return content.subdata(in: Int(range.lowerBound)..<Int(range.upperBound) + 1)
        }
        #expect(try Data(contentsOf: url) == content)
        #expect(fetched.starts.sorted() == [0, Int64(block), Int64(block * 2)])
        #expect(!SegmentedDownload.hasState(url))   // 完成即刪狀態檔
    }

    @Test func resumesOnlyMissingBlocks() async throws {
        let content = Data((0..<(block * 3)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: SegmentedDownload.stateURL(for: url)) }
        // 第一次：第 2 塊失敗（模擬中斷）→ 狀態檔保留已完成的區塊
        await #expect(throws: (any Error).self) {
            try await SegmentedDownload.run(to: url, totalSize: Int64(content.count), connections: 1, onProgress: { _ in }) { range in
                if range.lowerBound == Int64(block) { throw CancellationError() }
                return content.subdata(in: Int(range.lowerBound)..<Int(range.upperBound) + 1)
            }
        }
        #expect(SegmentedDownload.hasState(url))
        let fetched = Fetched()
        try await SegmentedDownload.run(to: url, totalSize: Int64(content.count), connections: 2, onProgress: { _ in }) { range in
            fetched.add(range.lowerBound)
            return content.subdata(in: Int(range.lowerBound)..<Int(range.upperBound) + 1)
        }
        #expect(!fetched.starts.contains(0))          // 第 0 塊上次已完成，不重抓
        #expect(try Data(contentsOf: url) == content)
    }

    @Test func continuesFromSingleConnectionPrefix() {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: Data(count: block + 100))
        // 單一連線留下 1 塊多的前段 → 第 0 塊視為完成，第 1 塊（不完整）重抓
        let state = SegmentedDownload.loadState(url, size: Int64(block * 3))
        #expect(state.done == [0])
    }

    @Test func parsesPgetStatus() {
        let text = "size=300\n0.pos=50\n0.limit=100\n1.pos=130\n1.limit=200\n2.pos=200\n2.limit=300\n"
        // 段 0：0→50＝50；段 1：100→130＝30；段 2：200→200＝0
        #expect(FTPFileSource.pgetDownloaded(text) == 80)
        #expect(FTPFileSource.pgetDownloaded("garbage") == nil)
    }

    @Test func optionsForLargeFiles() {
        var options = ConnectionOptions.Resolved()
        options.parallelTransfers = 3
        options.maxConnections = 4
        options.largeFileThresholdMB = 200
        #expect(options.largeFileThreshold == 200 << 20)
        #expect(options.connectionPoolSize == 6)        // 子執行器 2 ＋ 主執行器 4 條
        #expect(ExecutorLanes(parallelTransfers: 1) == nil)
    }
}
