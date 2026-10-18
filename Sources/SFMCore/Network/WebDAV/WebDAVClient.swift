import Foundation

/// 一筆 PROPFIND 結果。
struct DAVEntry: Sendable, Equatable {
    /// 已解碼的伺服器路徑：`/` 開頭、不帶結尾 `/`；根目錄為 `/`。
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?
}

/// 伺服器支援的「部分寫入」方式（WebDAV 標準沒有定義；探測做法見 `probePartialWrite`）。
enum PartialWriteMethod: String, Sendable {
    /// Apache mod_dav：`PUT` + `Content-Range: bytes a-b/*`
    case contentRange
    /// SabreDAV（Nextcloud 等）：`PATCH` + `X-Update-Range`
    case sabrePatch
    case none
}

/// async WebDAV 用戶端（移植自 nas_webdav 的同步版 `WebDAVClient`）。
///
/// 與原版差異：
/// - 改 async（FileSource 的呼叫端是 Swift 併發，不需原版給 FUSE 執行緒用的 semaphore）。
/// - 上傳／下載以 task delegate 回報進度；下載支援 Range 接續（續傳）。
/// - 錯誤轉成 `NetworkError`（原版是給 FUSE 的 errno）。
/// - 不含 FUSE 才需要的區塊讀取快取。
///
/// 路徑：伺服器上的絕對路徑（`/home/a.txt`），`baseURL` 只有 scheme＋主機＋埠。
/// 執行緒安全：URLSession 可並行；可變狀態（探測結果）以 lock 保護。
final class WebDAVClient: @unchecked Sendable {
    let baseURL: URL
    private let session: URLSession
    private let trust: TLSTrustDelegate
    private let authorization: String
    private let retries: Int
    private let retryDelay: Duration
    private let lock = NSLock()
    private var probed: PartialWriteMethod?

    /// 最近一次 TLS 交握看到的伺服器憑證指紋（供「信任此憑證」用）
    var lastSeenFingerprint: String? { trust.lastSeenFingerprint }

    init(baseURL: URL, username: String, password: String, pinnedSHA256: String,
         options: ConnectionOptions.Resolved) {
        self.baseURL = baseURL
        self.trust = TLSTrustDelegate(pinnedSHA256: pinnedSHA256, username: username, password: password,
                                      verifyCertificate: options.verifyCertificate)
        self.retries = max(0, options.retries)
        self.retryDelay = .seconds(max(0, options.retryDelaySeconds))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeInterval(max(5, options.timeoutSeconds))
        config.timeoutIntervalForResource = 7 * 86_400   // 大檔傳輸不設總時限（逾時只看「多久沒資料」）
        config.httpMaximumConnectionsPerHost = options.connectionPoolSize
        config.tlsMinimumSupportedProtocolVersion = options.minimumTLS.secProtocol
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
        // 預先帶 Basic：省掉每個請求一次 401 往返。http:// 時帳密為明文——UI 已標示「未加密」警告。
        self.authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    deinit { session.invalidateAndCancel() }

    // MARK: 路徑 ↔ URL

    /// 路徑片段允許的字元：urlPathAllowed 去掉分隔用的 `/` 與 `;`
    private static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;"))

    /// 伺服器路徑 → 完整 URL。
    /// macOS 傳入的檔名可能是 NFD（分解形式），Synology 等以 NFC 儲存，所以先正規化為 NFC。
    func url(for path: String, directory: Bool = false) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let encoded = path.precomposedStringWithCanonicalMapping
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? String($0) }
        var full = encoded.isEmpty ? "/" : "/" + encoded.joined(separator: "/")
        // 部分伺服器（IIS、某些 NAS）對集合要求結尾 `/`，否則 MKCOL／COPY 回 301
        if directory, !full.hasSuffix("/") { full += "/" }
        comps.percentEncodedPath = full
        return comps.url!
    }

    /// 伺服器回傳的 href（絕對 URL 或絕對路徑，百分比編碼）→ 已解碼的伺服器路徑
    func path(fromHref href: String) -> String? {
        guard let url = URL(string: href, relativeTo: baseURL) else { return nil }
        var path = url.absoluteURL.path(percentEncoded: false).precomposedStringWithCanonicalMapping
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    // MARK: 請求基礎

    private func request(_ method: String, _ path: String, directory: Bool = false,
                         headers: [String: String] = [:]) -> URLRequest {
        var req = URLRequest(url: url(for: path, directory: directory))
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        return req
    }

    /// 送出請求；2xx（或 `accept` 內）回傳資料與回應，其餘轉成 `NetworkError`。
    /// 傳輸層錯誤（逾時、斷線）依選項重試——只用於冪等的請求（PROPFIND、GET、DELETE…）。
    @discardableResult
    private func send(_ req: URLRequest, body: Data? = nil, accept: Set<Int> = [], idempotent: Bool = true,
                      what: String) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, response) = if let body {
                    try await session.upload(for: req, from: body)
                } else {
                    try await session.data(for: req)
                }
                return try check(response, data: data, accept: accept, what: what)
            } catch let error as URLError where idempotent && attempt < retries && Self.isTransient(error) {
                attempt += 1
                try await Task.sleep(for: retryDelay)
            } catch {
                throw map(error, what: what)
            }
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code)
    }

    private func check(_ response: URLResponse, data: Data, accept: Set<Int>, what: String) throws -> (Data, HTTPURLResponse) {
        guard let http = response as? HTTPURLResponse else { throw NetworkError.server("\(what): no HTTP response") }
        guard (200..<300).contains(http.statusCode) || accept.contains(http.statusCode) else {
            throw Self.httpError(http.statusCode, what: what)
        }
        return (data, http)
    }

    static func httpError(_ status: Int, what: String) -> NetworkError {
        switch status {
        case 401: return .authenticationFailed("HTTP 401")
        case 403: return .server(String(localized: "\(what): permission denied (HTTP 403)"))
        case 404, 409: return .notFound(what)
        case 405, 412: return .alreadyExists(what)
        case 507, 413: return .server(String(localized: "\(what): not enough space on the server (HTTP \(status))"))
        default: return .server("\(what): HTTP \(status)")
        }
    }

    /// URLSession 錯誤 → NetworkError；憑證被拒時附上看到的指紋
    func map(_ error: Error, what: String) -> Error {
        if error is NetworkError || error is CancellationError { return error }
        guard let urlError = error as? URLError else { return error }
        if urlError.code == .cancelled {
            // cancelled 有三種來源：Swift Task 被取消、TLS 委派拒絕憑證、認證委派放棄（帳密錯，同一 space 第二次挑戰）
            if Task.isCancelled { return CancellationError() }
            if trust.trustRejected { return NetworkError.untrustedCertificate(fingerprint: trust.lastSeenFingerprint) }
            return NetworkError.authenticationFailed("HTTP 401")
        }
        switch urlError.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            return NetworkError.untrustedCertificate(fingerprint: trust.lastSeenFingerprint)
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return NetworkError.authenticationFailed(urlError.localizedDescription)
        default:
            return NetworkError.unreachable(urlError.localizedDescription)
        }
    }

    // MARK: 讀取類

    private static let propfindBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop>
        <d:resourcetype/><d:getcontentlength/><d:getlastmodified/>
        </d:prop></d:propfind>
        """.utf8)

    /// PROPFIND。depth 0：只有 path 本身；depth 1：本身＋直接子項。
    func propfind(_ path: String, depth: Int) async throws -> [DAVEntry] {
        let req = request("PROPFIND", path, directory: depth > 0,
                          headers: ["Depth": "\(depth)", "Content-Type": "application/xml; charset=utf-8"])
        let (data, http) = try await send(req, body: Self.propfindBody, what: "PROPFIND \(path)")
        guard http.statusCode == 207 else { throw Self.httpError(http.statusCode, what: "PROPFIND \(path)") }
        return MultistatusParser.parse(data).compactMap { response in
            guard let entryPath = self.path(fromHref: response.href) else { return nil }
            return DAVEntry(path: entryPath, isDirectory: response.isCollection, size: response.contentLength ?? 0,
                            modified: response.lastModified)
        }
    }

    /// 單一項目的資訊；不存在時為 nil
    func entry(_ path: String) async throws -> DAVEntry? {
        do {
            return try await propfind(path, depth: 0).first
        } catch NetworkError.notFound {
            return nil
        }
    }

    /// OPTIONS 的 `DAV` 標頭（偵測 sabredav-partialupdate）
    func davCapabilities() async throws -> String {
        let (_, http) = try await send(request("OPTIONS", "/"), what: "OPTIONS")
        return http.value(forHTTPHeaderField: "DAV") ?? ""
    }

    /// 下載到本機檔案。`offset > 0` 時以 Range 接續，附加到既有的本機檔案；
    /// 伺服器忽略 Range（回 200 整檔）時改為覆寫，結果仍正確。
    func download(_ path: String, to localURL: URL, offset: Int64 = 0, totalSize: Int64?,
                  onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var req = request("GET", path)
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let progress = TransferProgressDelegate { written, expected in
            let total = totalSize ?? (expected > 0 ? offset + expected : 0)
            if total > 0 { onProgress(min(1, Double(offset + written) / Double(total))) }
        }
        let temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await session.download(for: req, delegate: progress)
        } catch {
            throw map(error, what: "GET \(path)")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (_, http) = try check(response, data: Data(), accept: [], what: "GET \(path)")
        let fm = FileManager.default
        if offset > 0, http.statusCode == 206 {
            // 附加：分塊讀寫，避免大檔整份載入記憶體
            let writer = try FileHandle(forWritingTo: localURL)
            let reader = try FileHandle(forReadingFrom: temporary)
            defer { try? writer.close(); try? reader.close() }
            try writer.truncate(atOffset: UInt64(offset))
            while let chunk = try reader.read(upToCount: 8 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
            }
        } else {
            try? fm.removeItem(at: localURL)
            try fm.moveItem(at: temporary, to: localURL)
        }
        onProgress(1)
    }

    // MARK: 寫入類

    func put(_ path: String, file: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let progress = TransferProgressDelegate(upload: true) { sent, expected in
            if expected > 0 { onProgress(min(1, Double(sent) / Double(expected))) }
        }
        do {
            let (data, response) = try await session.upload(for: request("PUT", path), fromFile: file, delegate: progress)
            _ = try check(response, data: data, accept: [], what: "PUT \(path)")
        } catch {
            throw map(error, what: "PUT \(path)")
        }
        onProgress(1)
    }

    func put(_ path: String, data: Data) async throws {
        try await send(request("PUT", path), body: data, idempotent: false, what: "PUT \(path)")
    }

    /// 部分寫入：把 data 寫到 path 的 offset 處（可延伸檔尾）。method 必須是探測過可用的方式。
    func write(_ path: String, offset: Int64, data: Data, method: PartialWriteMethod) async throws {
        let range = "\(offset)-\(offset + Int64(data.count) - 1)"
        switch method {
        case .contentRange:
            let req = request("PUT", path, headers: ["Content-Range": "bytes \(range)/*"])
            try await send(req, body: data, idempotent: false, what: "PUT(range) \(path)")
        case .sabrePatch:
            let req = request("PATCH", path, headers: ["Content-Type": "application/x-sabredav-partialupdate",
                                                       "X-Update-Range": "bytes=\(range)"])
            try await send(req, body: data, idempotent: false, what: "PATCH \(path)")
        case .none:
            throw NetworkError.server("partial write not supported")
        }
    }

    func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        let req = request("GET", path, headers: ["Range": "bytes=\(offset)-\(offset + Int64(length) - 1)"])
        let (data, http) = try await send(req, accept: [416], what: "GET \(path)")
        switch http.statusCode {
        case 416: return Data()
        case 206: return data
        default:
            guard offset < Int64(data.count) else { return Data() }
            return data.subdata(in: Int(offset)..<min(Int(offset) + length, data.count))
        }
    }

    func delete(_ path: String) async throws {
        try await send(request("DELETE", path), what: "DELETE \(path)")
    }

    func mkcol(_ path: String) async throws {
        try await send(request("MKCOL", path, directory: true), idempotent: false, what: "MKCOL \(path)")
    }

    /// MOVE／COPY（伺服器端完成，不經 Mac）。`overwrite: false`＝目的已存在時失敗（412），絕不覆蓋既有資料
    func transfer(_ method: String, _ from: String, to: String, isDirectory: Bool) async throws {
        var headers = ["Destination": url(for: to, directory: isDirectory).absoluteString, "Overwrite": "F"]
        if method == "COPY" { headers["Depth"] = "infinity" }
        try await send(request(method, from, directory: isDirectory, headers: headers), idempotent: false,
                       what: "\(method) \(from)")
    }

    // MARK: 部分寫入探測

    /// 以實際試寫判斷伺服器是否支援部分寫入（只信實測，不信標頭宣稱）；結果快取於此用戶端。
    ///
    /// 若伺服器默默忽略 Content-Range，`PUT` 會把整檔覆寫成那一小段——拿真檔案試就會毀資料，
    /// 所以只在 `directory` 下建立隱藏的探測檔：寫 "AAAA" → 於 offset 2 寫 "B"（覆寫中段）
    /// → 於 offset 4 寫 "CC"（延伸檔尾）→ 讀回必須是 "AABACC"，結束後刪除。
    func partialWriteMethod(probingIn directory: String) async -> PartialWriteMethod {
        if let cached = lock.withLock({ probed }) { return cached }
        let probe = RemotePath.join(directory, ".sfm-probe-\(UUID().uuidString)")
        var candidates: [PartialWriteMethod] = [.contentRange]
        if let dav = try? await davCapabilities(), dav.lowercased().contains("sabredav-partialupdate") {
            candidates.insert(.sabrePatch, at: 0)
        }
        var result = PartialWriteMethod.none
        for method in candidates {
            do {
                try await put(probe, data: Data("AAAA".utf8))
                try await write(probe, offset: 2, data: Data("B".utf8), method: method)
                try await write(probe, offset: 4, data: Data("CC".utf8), method: method)
                if try await read(probe, offset: 0, length: 64) == Data("AABACC".utf8) { result = method; break }
            } catch {
                continue
            }
        }
        try? await delete(probe)
        lock.withLock { probed = result }
        return result
    }
}

/// 單一 URLSession task 的進度委派（session 層的 TLS／認證仍由 `TLSTrustDelegate` 處理：
/// task delegate 沒實作 challenge 方法時，URLSession 會轉給 session delegate）。
final class TransferProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let upload: Bool
    private let report: @Sendable (Int64, Int64) -> Void

    init(upload: Bool = false, report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.upload = upload
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if upload { report(totalBytesSent, totalBytesExpectedToSend) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten, totalBytesExpectedToWrite)
    }

    // async `download(for:delegate:)` 自行處理檔案，這個必要方法不會被用到
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
