import Foundation

/// 網路帳號 → FileSource。**唯一**知道「協定 → 實作」對應的地方；
/// App 層只拿到 `any FileSource`，不認識各協定的型別。
public enum NetworkSourceFactory {
    /// 由鑰匙圈讀出祕密（密碼或 pCloud token）；沒有時為 nil。
    /// SFTP 用金鑰登入時不需要密碼，回傳空字串。
    public static func storedSecret(for account: NetworkAccount) -> String? {
        switch account.protocol {
        case .pcloud: return CredentialStore.pcloudToken(for: account)
        case .sftp where account.sftpAuth == .key: return ""
        default: return CredentialStore.password(for: account)
        }
    }

    /// 建立來源。`secret` 省略時從鑰匙圈讀（測試連線時傳入表單上尚未儲存的密碼）。
    public static func make(_ account: NetworkAccount, options: ConnectionOptions.Resolved,
                            secret: String? = nil) throws -> any FileSource {
        guard let secret = secret ?? storedSecret(for: account) else { throw NetworkError.missingCredential }
        switch account.protocol {
        case .webdav:
            return WebDAVFileSource(account: account, password: secret, options: options)
        case .ftp, .sftp:
            guard let lftp = FTPFileSource.locateTool() else { throw NetworkError.lftpMissing }
            return FTPFileSource(account: account, password: secret, options: options, executable: lftp)
        case .pcloud:
            return PCloudFileSource(account: account, token: PCloudToken(keychainValue: secret), options: options)
        }
    }

    /// 測試連線：列出起始資料夾。成功回傳項目數。
    public static func test(_ source: any FileSource) async throws -> Int {
        try await source.list(source.homePath, includeHidden: true).count
    }

    /// 來源最近一次 TLS 交握看到的憑證指紋（WebDAV；其他協定為 nil）
    public static func lastSeenFingerprint(of source: any FileSource) -> String? {
        (source as? WebDAVFileSource)?.lastSeenFingerprint
    }
}

public extension NetworkSourceFactory {
    /// pCloud 登入後查帳號 email（帳號清單顯示用）
    static func pcloudEmail(token: PCloudToken, region: PCloudRegion, options: ConnectionOptions.Resolved) async throws -> String? {
        try await PCloudClient(region: region, token: token, options: options).userEmail()
    }
}
