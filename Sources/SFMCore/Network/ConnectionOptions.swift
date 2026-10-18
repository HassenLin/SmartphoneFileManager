import Foundation
import Security

/// WebDAV 上傳續傳的方式
public enum PartialWriteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 第一次續傳時以隱藏探測檔實測（Apache `PUT Content-Range`／SabreDAV `PATCH`），不支援就整檔重傳
    case auto
    /// 一律整檔重傳（伺服器宣稱支援但實作有問題時用）
    case off

    public var id: String { rawValue }
}

/// 網路帳號的進階選項。每欄 **nil＝沿用全域預設**（設定 → 網路），
/// 帳號選項視窗可逐項覆寫或還原；`resolved(defaults:)` 產生具體值交給 FileSource。
///
/// 為什麼不讓 FileSource 直接讀 UserDefaults：core 層要能單元測試、也不該知道 UI 的設定存在哪。
public struct ConnectionOptions: Codable, Hashable, Sendable {
    // 連線
    public var timeoutSeconds: Int?
    public var retries: Int?
    public var retryDelaySeconds: Int?
    public var maxConnections: Int?
    /// 同時傳輸的檔案數（工作佇列對此帳號一次上傳／下載幾個檔案；1＝逐檔）。見 `FileSource.maxParallelTransfers`
    public var parallelTransfers: Int?
    /// 閒置多久後斷線（lftp `net:idle`）
    public var idleSeconds: Int?

    // 傳輸（FTP）
    /// 伺服器檔名編碼（lftp `ftp:charset`），例如舊 NAS 的 Big5；空字串＝UTF-8
    public var ftpCharset: String?
    /// 主動模式回報給伺服器的外部 IP（lftp `ftp:port-ipv4`，用戶端在 NAT 後時填）；空＝自動
    public var activeAddress: String?
    /// 主動模式的本機埠範圍（lftp `ftp:port-range`，例如 `40000-40100`）；空＝任意
    public var activePortRange: String?
    /// LIST 回傳時間的時區（lftp `ftp:timezone`，例如 `Asia/Taipei`）；空＝UTC（MLSD 一律 UTC，不受影響）
    public var serverTimeZone: String?

    // 安全性
    /// 驗證伺服器 TLS 憑證（FTPS 用 lftp `ssl:verify-certificate`；WebDAV 有釘選指紋時以指紋為準）
    public var verifyCertificate: Bool?
    /// WebDAV／pCloud 的 TLS 最低版本
    public var minimumTLS: TLSVersion?

    // 進階
    /// 額外的 lftp `set` 指令（每行一條，例如 `set ftp:use-feat no`；FTP／SFTP 才有效）
    public var extraLftpCommands: String?
    public var partialWrite: PartialWriteMode?

    public init() {}

    /// 每欄都有值（全域預設的編輯表單與帳號選項共用同一個表單時用）
    public init(resolved r: Resolved) {
        timeoutSeconds = r.timeoutSeconds
        retries = r.retries
        retryDelaySeconds = r.retryDelaySeconds
        maxConnections = r.maxConnections
        parallelTransfers = r.parallelTransfers
        idleSeconds = r.idleSeconds
        ftpCharset = r.ftpCharset
        activeAddress = r.activeAddress
        activePortRange = r.activePortRange
        serverTimeZone = r.serverTimeZone
        verifyCertificate = r.verifyCertificate
        minimumTLS = r.minimumTLS
        extraLftpCommands = r.extraLftpCommands
        partialWrite = r.partialWrite
    }

    /// 是否有任何一項覆寫全域預設（清單顯示「自訂選項」標記用）
    public var hasOverrides: Bool { self != ConnectionOptions() }

    public func resolved(defaults: Resolved) -> Resolved {
        Resolved(
            timeoutSeconds: timeoutSeconds ?? defaults.timeoutSeconds,
            retries: retries ?? defaults.retries,
            retryDelaySeconds: retryDelaySeconds ?? defaults.retryDelaySeconds,
            maxConnections: maxConnections ?? defaults.maxConnections,
            parallelTransfers: parallelTransfers ?? defaults.parallelTransfers,
            idleSeconds: idleSeconds ?? defaults.idleSeconds,
            ftpCharset: ftpCharset ?? defaults.ftpCharset,
            activeAddress: activeAddress ?? defaults.activeAddress,
            activePortRange: activePortRange ?? defaults.activePortRange,
            serverTimeZone: serverTimeZone ?? defaults.serverTimeZone,
            verifyCertificate: verifyCertificate ?? defaults.verifyCertificate,
            minimumTLS: minimumTLS ?? defaults.minimumTLS,
            extraLftpCommands: extraLftpCommands ?? defaults.extraLftpCommands,
            partialWrite: partialWrite ?? defaults.partialWrite)
    }

    /// 具體值（全域預設本身也是這個型別）
    public struct Resolved: Codable, Hashable, Sendable {
        public var timeoutSeconds = 30
        public var retries = 2
        public var retryDelaySeconds = 3
        public var maxConnections = 4
        /// 預設逐檔（與加入此選項前相同）；雲端／WebDAV 調高可明顯加快大量小檔
        public var parallelTransfers = 1
        public var idleSeconds = 180
        public var ftpCharset = ""
        public var activeAddress = ""
        public var activePortRange = ""
        public var serverTimeZone = ""
        public var verifyCertificate = true
        public var minimumTLS: TLSVersion = .tls12
        public var extraLftpCommands = ""
        public var partialWrite: PartialWriteMode = .auto

        public init() {}

        public init(timeoutSeconds: Int, retries: Int, retryDelaySeconds: Int, maxConnections: Int,
                    parallelTransfers: Int = 1, idleSeconds: Int,
                    ftpCharset: String, activeAddress: String, activePortRange: String, serverTimeZone: String,
                    verifyCertificate: Bool, minimumTLS: TLSVersion, extraLftpCommands: String,
                    partialWrite: PartialWriteMode) {
            self.timeoutSeconds = timeoutSeconds
            self.retries = retries
            self.retryDelaySeconds = retryDelaySeconds
            self.maxConnections = maxConnections
            self.parallelTransfers = parallelTransfers
            self.idleSeconds = idleSeconds
            self.ftpCharset = ftpCharset
            self.activeAddress = activeAddress
            self.activePortRange = activePortRange
            self.serverTimeZone = serverTimeZone
            self.verifyCertificate = verifyCertificate
            self.minimumTLS = minimumTLS
            self.extraLftpCommands = extraLftpCommands
            self.partialWrite = partialWrite
        }

        public static let standard = Resolved()

        /// HTTP 連線池大小：至少容納同時傳輸數，否則多出的傳輸只會在連線池排隊
        public var connectionPoolSize: Int { max(1, maxConnections, parallelTransfers) }
    }
}

public enum TLSVersion: String, Codable, CaseIterable, Identifiable, Sendable {
    case tls12, tls13

    public var id: String { rawValue }
    public var title: String { self == .tls12 ? "TLS 1.2" : "TLS 1.3" }

    public var secProtocol: tls_protocol_version_t { self == .tls12 ? .TLSv12 : .TLSv13 }
}

// 逐欄 decodeIfPresent：日後新增選項時，舊版存檔仍可讀
public extension ConnectionOptions.Resolved {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConnectionOptions.Resolved.standard
        self.init(
            timeoutSeconds: try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds,
            retries: try c.decodeIfPresent(Int.self, forKey: .retries) ?? d.retries,
            retryDelaySeconds: try c.decodeIfPresent(Int.self, forKey: .retryDelaySeconds) ?? d.retryDelaySeconds,
            maxConnections: try c.decodeIfPresent(Int.self, forKey: .maxConnections) ?? d.maxConnections,
            parallelTransfers: try c.decodeIfPresent(Int.self, forKey: .parallelTransfers) ?? d.parallelTransfers,
            idleSeconds: try c.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? d.idleSeconds,
            ftpCharset: try c.decodeIfPresent(String.self, forKey: .ftpCharset) ?? d.ftpCharset,
            activeAddress: try c.decodeIfPresent(String.self, forKey: .activeAddress) ?? d.activeAddress,
            activePortRange: try c.decodeIfPresent(String.self, forKey: .activePortRange) ?? d.activePortRange,
            serverTimeZone: try c.decodeIfPresent(String.self, forKey: .serverTimeZone) ?? d.serverTimeZone,
            verifyCertificate: try c.decodeIfPresent(Bool.self, forKey: .verifyCertificate) ?? d.verifyCertificate,
            minimumTLS: try c.decodeIfPresent(TLSVersion.self, forKey: .minimumTLS) ?? d.minimumTLS,
            extraLftpCommands: try c.decodeIfPresent(String.self, forKey: .extraLftpCommands) ?? d.extraLftpCommands,
            partialWrite: try c.decodeIfPresent(PartialWriteMode.self, forKey: .partialWrite) ?? d.partialWrite)
    }
}
