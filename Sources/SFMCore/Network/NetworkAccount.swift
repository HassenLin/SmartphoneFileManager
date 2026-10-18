import Foundation

/// 網路來源支援的協定。新增協定＝這裡加一個 case、`NetworkSourceFactory` 加一條對應、
/// 編輯器加該協定專屬欄位；`SourceID.Kind` 不需變動（一律為 `.network`）。
public enum NetworkProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case webdav, ftp, sftp, pcloud

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .webdav: return "WebDAV"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .pcloud: return "pCloud"
        }
    }

    /// 是否需要 lftp（外部工具，`brew install lftp`）
    public var needsLftp: Bool { self == .ftp || self == .sftp }
}

/// FTP 的加密方式
public enum FTPSecurity: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 純 FTP（明文，帳密與資料都不加密）
    case none
    /// FTPS explicit：連 21 埠後以 `AUTH TLS` 升級（最常見）
    case explicit
    /// FTPS implicit：一連線就是 TLS（預設 990 埠，較舊的做法）
    case implicit

    public var id: String { rawValue }
}

/// FTP 資料通道的建立方式
public enum FTPMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 被動（PASV／EPSV）：由用戶端連到伺服器，NAT／防火牆後的用戶端可用（預設）
    case passive
    /// 主動（PORT／EPRT）：由伺服器回連用戶端；用戶端在 NAT 後時需在選項指定外部位址與埠範圍
    case active

    public var id: String { rawValue }
}

/// SFTP 的登入方式
public enum SFTPAuth: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    /// 私鑰檔（`ssh -i`）；有密語的金鑰請先加入 ssh-agent
    case key

    public var id: String { rawValue }
}

/// pCloud 的資料中心。帳號建立時就固定在其中一區，API host 不同、互不相通
/// （打錯區會回 2000 登入失敗），因此所有請求的 host 都由這裡決定，不寫死。
public enum PCloudRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 美國（locationid 1）
    case us
    /// 歐洲（盧森堡，locationid 2）
    case eu

    public var id: String { rawValue }

    public var apiHost: String {
        switch self {
        case .us: return "api.pcloud.com"
        case .eu: return "eapi.pcloud.com"
        }
    }

    /// OAuth 回呼的 `locationid` → 地區；未知值為 nil
    public init?(locationID: String) {
        switch locationID {
        case "1": self = .us
        case "2": self = .eu
        default: return nil
        }
    }

    /// OAuth 回呼的 `hostname`（例如 `eapi.pcloud.com`）→ 地區
    public init?(apiHost: String) {
        guard let region = Self.allCases.first(where: { $0.apiHost == apiHost.lowercased() }) else { return nil }
        self = region
    }
}

/// 一個網路帳號：協定＋伺服器＋登入身分（＋連線選項）。
/// 密碼／token 不在這裡，存登入鑰匙圈（`CredentialStore`）。
public struct NetworkAccount: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    /// 顯示名稱；空字串時以「帳號@主機」顯示（`displayName`）
    public var name = ""
    public var `protocol`: NetworkProtocol = .webdav
    public var host = ""
    /// nil＝協定預設埠（`effectivePort`）
    public var port: Int?
    /// pCloud 為登入後的 email（只供顯示）
    public var username = ""
    /// 起始遠端路徑（窗格的「起始資料夾」）
    public var rootPath = "/"

    // MARK: 協定專屬

    /// WebDAV：https（預設）或 http
    public var useTLS = true
    /// FTP：加密方式與資料通道模式
    public var ftpSecurity: FTPSecurity = .explicit
    public var ftpMode: FTPMode = .passive
    /// SFTP：登入方式與私鑰路徑
    public var sftpAuth: SFTPAuth = .password
    public var sftpKeyPath = ""
    /// pCloud：資料中心
    public var pcloudRegion: PCloudRegion = .us
    /// 釘選的伺服器憑證 SHA-256（hex，小寫無冒號；WebDAV 的自簽 NAS 用）；空字串＝走系統信任鏈
    public var pinnedCertSHA256 = ""

    /// 進階選項（每欄 nil＝沿用全域預設）
    public var options = ConnectionOptions()

    public init(protocol: NetworkProtocol = .webdav) {
        self.protocol = `protocol`
    }

    public var sourceID: SourceID { .network(id) }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if self.protocol == .pcloud { return username.isEmpty ? "pCloud" : "pCloud (\(username))" }
        return username.isEmpty ? host : "\(username)@\(host)"
    }

    /// 帳密與資料是否加密傳送（UI 依此顯示「未加密」警告）
    public var isEncrypted: Bool {
        switch self.protocol {
        case .webdav: return useTLS
        case .ftp: return ftpSecurity != .none
        case .sftp, .pcloud: return true
        }
    }

    /// 協定標籤（清單「協定」欄）：FTP 加密時顯示 FTPS、pCloud 帶地區
    public var protocolLabel: String {
        switch self.protocol {
        case .ftp where ftpSecurity != .none: return "FTPS"
        case .pcloud: return "pCloud \(pcloudRegion.rawValue.uppercased())"
        default: return self.protocol.title
        }
    }

    public var defaultPort: Int {
        switch self.protocol {
        case .webdav: return useTLS ? 443 : 80
        case .ftp: return ftpSecurity == .implicit ? 990 : 21
        case .sftp: return 22
        case .pcloud: return 443
        }
    }

    public var effectivePort: Int { port ?? defaultPort }

    /// 「主機:埠」（清單「伺服器」欄）；預設埠時省略埠
    public var serverLabel: String {
        if self.protocol == .pcloud { return pcloudRegion.apiHost }
        return port.map { "\(host):\($0)" } ?? host
    }

    /// 回傳設定錯誤訊息；nil 表示可儲存
    public func validationError() -> String? {
        if self.protocol != .pcloud {
            let trimmed = host.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return String(localized: "Server is required.") }
            if trimmed.contains("/") || trimmed.contains(" ") {
                return String(localized: "Enter only the host name or IP address (no scheme or path).")
            }
            if let port, !(1...65535).contains(port) { return String(localized: "Port must be between 1 and 65535.") }
        }
        if self.protocol == .sftp, sftpAuth == .key, sftpKeyPath.isEmpty {
            return String(localized: "Choose a private key file.")
        }
        if !pinnedCertSHA256.isEmpty, Self.normalizeFingerprint(pinnedCertSHA256).count != 64 {
            return String(localized: "Pinned SHA-256 must be 64 hex characters.")
        }
        return nil
    }

    /// 指紋正規化：去掉冒號／空白、轉小寫（使用者可能從瀏覽器貼上 `AB:CD:…`）
    public static func normalizeFingerprint(_ value: String) -> String {
        value.lowercased().filter { $0.isHexDigit }
    }

    /// 起始路徑正規化（一定 `/` 開頭）
    public var normalizedRootPath: String {
        RemotePath.normalize(rootPath.isEmpty ? "/" : (rootPath.hasPrefix("/") ? rootPath : "/" + rootPath))
    }
}

// 逐欄 decodeIfPresent：日後新增欄位時，舊版 accounts.json 仍可讀（缺的欄位用預設值）
public extension NetworkAccount {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = NetworkAccount()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? base.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? base.name
        self.protocol = try c.decodeIfPresent(NetworkProtocol.self, forKey: .protocol) ?? base.protocol
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? base.host
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? base.username
        rootPath = try c.decodeIfPresent(String.self, forKey: .rootPath) ?? base.rootPath
        useTLS = try c.decodeIfPresent(Bool.self, forKey: .useTLS) ?? base.useTLS
        ftpSecurity = try c.decodeIfPresent(FTPSecurity.self, forKey: .ftpSecurity) ?? base.ftpSecurity
        ftpMode = try c.decodeIfPresent(FTPMode.self, forKey: .ftpMode) ?? base.ftpMode
        sftpAuth = try c.decodeIfPresent(SFTPAuth.self, forKey: .sftpAuth) ?? base.sftpAuth
        sftpKeyPath = try c.decodeIfPresent(String.self, forKey: .sftpKeyPath) ?? base.sftpKeyPath
        pcloudRegion = try c.decodeIfPresent(PCloudRegion.self, forKey: .pcloudRegion) ?? base.pcloudRegion
        pinnedCertSHA256 = try c.decodeIfPresent(String.self, forKey: .pinnedCertSHA256) ?? base.pinnedCertSHA256
        options = try c.decodeIfPresent(ConnectionOptions.self, forKey: .options) ?? base.options
    }
}
