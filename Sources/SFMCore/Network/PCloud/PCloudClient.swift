import Foundation

/// pCloud HTTP JSON API 用戶端（https://docs.pcloud.com）。
///
/// - **地區**：美國帳號只能打 `api.pcloud.com`、歐洲帳號只能打 `eapi.pcloud.com`（`PCloudRegion`）；
///   打錯區會回 2000／2094，所以 host 由帳號的地區決定，不寫死。
/// - 認證：OAuth2 access token 以 `Authorization: Bearer` 送出；帳號密碼登入的 auth token
///   依 API 規定以 `auth=` 參數送出（見 `PCloudToken`）。
/// - 回應一律 HTTP 200，成敗看 JSON 的 `result`（0＝成功），錯誤碼對應見 `error(_:)`。
/// - 所有操作以**路徑**指定（`path=`／`topath=`），與 FileSource 的路徑模型一致，不需維護 id 對照。
final class PCloudClient: @unchecked Sendable {
    let region: PCloudRegion
    private let token: PCloudToken
    private let session: URLSession
    private let trust: TLSTrustDelegate

    init(region: PCloudRegion, token: PCloudToken, options: ConnectionOptions.Resolved) {
        self.region = region
        self.token = token
        self.trust = TLSTrustDelegate(pinnedSHA256: "", username: "", password: "")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeInterval(max(5, options.timeoutSeconds))
        config.timeoutIntervalForResource = 7 * 86_400
        config.httpMaximumConnectionsPerHost = options.connectionPoolSize
        config.tlsMinimumSupportedProtocolVersion = options.minimumTLS.secProtocol
        config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: 回應模型

    struct Metadata: Decodable, Sendable {
        let name: String
        let isfolder: Bool
        let size: Int64?
        let modified: String?
        let contents: [Metadata]?
    }

    private struct Envelope: Decodable {
        let result: Int
        let error: String?
        let metadata: Metadata?
        let hosts: [String]?
        let path: String?
        let email: String?
    }

    // MARK: 請求

    func url(_ method: String, _ parameters: [String: String]) -> URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = region.apiHost
        comps.path = "/" + method
        comps.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLQueryItem 不會編碼 `+`，伺服器會把它當空白——檔名含 + 時必須自行編碼
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url!
    }

    private func request(_ method: String, _ parameters: [String: String], httpMethod: String = "GET") -> URLRequest {
        var parameters = parameters
        if token.kind == .session { parameters["auth"] = token.value }
        var req = URLRequest(url: url(method, parameters))
        req.httpMethod = httpMethod
        if token.kind == .oauth { req.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization") }
        return req
    }

    @discardableResult
    private func call(_ method: String, _ parameters: [String: String]) async throws -> Envelope {
        let data: Data
        do {
            (data, _) = try await session.data(for: request(method, parameters))
        } catch {
            throw Self.map(error)
        }
        return try decode(data, method: method)
    }

    @discardableResult
    private func decode(_ data: Data, method: String) throws -> Envelope {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw NetworkError.server("pCloud \(method): unexpected response")
        }
        guard envelope.result == 0 else { throw Self.error(envelope.result, envelope.error ?? "", method: method) }
        return envelope
    }

    /// pCloud 錯誤碼 → NetworkError（https://docs.pcloud.com/errors/）
    static func error(_ code: Int, _ message: String, method: String) -> NetworkError {
        let detail = message.isEmpty ? "pCloud \(method): error \(code)" : "\(message) (\(code))"
        switch code {
        case 1000, 2000, 2094, 2095, 4000: return .authenticationFailed(detail)
        case 2002, 2005, 2009, 2055: return .notFound(detail)
        case 2004: return .alreadyExists(detail)
        default: return .server(detail)
        }
    }

    static func map(_ error: Error) -> Error {
        if error is NetworkError || error is CancellationError { return error }
        guard let urlError = error as? URLError else { return error }
        if urlError.code == .cancelled { return CancellationError() }
        return NetworkError.unreachable(urlError.localizedDescription)
    }

    // MARK: API

    func listFolder(_ path: String) async throws -> [Metadata] {
        try await call("listfolder", ["path": path]).metadata?.contents ?? []
    }

    /// 檔案或資料夾的資訊；不存在時為 nil。
    /// `stat` 只適用於檔案，資料夾改用 `listfolder nofiles=1`（只回傳子資料夾，最省流量的資料夾查詢）。
    func metadata(_ path: String) async throws -> Metadata? {
        do {
            return try await call("stat", ["path": path]).metadata
        } catch NetworkError.notFound {
        } catch NetworkError.server {
            // 對資料夾 stat 會回 2010 等非「不存在」錯誤，同樣改查資料夾
        }
        do {
            return try await call("listfolder", ["path": path, "nofiles": "1", "noshares": "1"]).metadata
        } catch NetworkError.notFound {
            return nil
        }
    }

    func createFolder(_ path: String) async throws { try await call("createfolder", ["path": path]) }
    func deleteFile(_ path: String) async throws { try await call("deletefile", ["path": path]) }
    func deleteFolderRecursive(_ path: String) async throws { try await call("deletefolderrecursive", ["path": path]) }

    func rename(_ path: String, to target: String, isFolder: Bool) async throws {
        try await call(isFolder ? "renamefolder" : "renamefile", ["path": path, "topath": target])
    }

    /// 伺服器端複製（不經 Mac）；`noover=1` 目的已存在時失敗，絕不覆蓋。
    /// 資料夾：先建立目的資料夾，再以 `copycontentonly` 把內容複製進去——目的路徑語意才與檔案一致。
    func copy(_ path: String, to target: String, isFolder: Bool) async throws {
        if isFolder {
            try await createFolder(target)
            try await call("copyfolder", ["path": path, "topath": target + "/", "noover": "1", "copycontentonly": "1"])
        } else {
            try await call("copyfile", ["path": path, "topath": target, "noover": "1"])
        }
    }

    func userEmail() async throws -> String? { try await call("userinfo", [:]).email }

    /// 下載：`getfilelink` 取得 CDN 連結（host 依該次回應，兩區不同）後 GET；`offset > 0` 以 Range 接續附加
    func download(_ path: String, to localURL: URL, offset: Int64, totalSize: Int64?,
                  onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let link = try await call("getfilelink", ["path": path, "forcedownload": "1"])
        guard let host = link.hosts?.first, let linkPath = link.path,
              let url = URL(string: "https://\(host)\(linkPath)") else {
            throw NetworkError.server("pCloud getfilelink: no download link")
        }
        var req = URLRequest(url: url)
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let progress = TransferProgressDelegate { written, expected in
            let total = totalSize ?? (expected > 0 ? offset + expected : 0)
            if total > 0 { onProgress(min(1, Double(offset + written) / Double(total))) }
        }
        let temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await session.download(for: req, delegate: progress)
        } catch {
            throw Self.map(error)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetworkError.server("pCloud download: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let fm = FileManager.default
        if offset > 0, http.statusCode == 206 {
            let writer = try FileHandle(forWritingTo: localURL)
            let reader = try FileHandle(forReadingFrom: temporary)
            defer { try? writer.close(); try? reader.close() }
            try writer.truncate(atOffset: UInt64(offset))
            while let chunk = try reader.read(upToCount: 8 << 20), !chunk.isEmpty { try writer.write(contentsOf: chunk) }
        } else {
            try? fm.removeItem(at: localURL)
            try fm.moveItem(at: temporary, to: localURL)
        }
        onProgress(1)
    }

    /// 上傳：`uploadfile` 以 PUT＋`filename` 參數時，請求本文即檔案內容（不需 multipart）。
    /// 同名檔案直接覆寫（衝突已由工作佇列處理）；`nopartial=1`：中斷時伺服器不留下殘缺檔。
    func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let req = request("uploadfile", ["path": RemotePath.parent(of: path), "filename": RemotePath.name(of: path),
                                         "nopartial": "1"], httpMethod: "PUT")
        let progress = TransferProgressDelegate(upload: true) { sent, expected in
            if expected > 0 { onProgress(min(1, Double(sent) / Double(expected))) }
        }
        let data: Data
        do {
            (data, _) = try await session.upload(for: req, fromFile: localURL, delegate: progress)
        } catch {
            throw Self.map(error)
        }
        try decode(data, method: "uploadfile")
        onProgress(1)
    }

    // MARK: 日期

    /// `modified`：`Thu, 21 Mar 2013 18:31:57 +0000`
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static func parseDate(_ text: String?) -> Date? { text.flatMap { dateFormatter.date(from: $0) } }
}
