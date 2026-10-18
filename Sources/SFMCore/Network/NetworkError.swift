import Foundation

/// 網路來源共用的錯誤。窗格的錯誤畫面與帳號編輯器的「測試連線」依 case 提供對應動作
/// （編輯帳號、信任此憑證、安裝 lftp、重新登入 pCloud）。
public enum NetworkError: LocalizedError, Equatable, Sendable {
    /// 帳密錯誤／token 失效
    case authenticationFailed(String)
    /// 連不上（DNS、拒絕連線、逾時、斷線）
    case unreachable(String)
    /// 伺服器憑證不受信任；附上看到的葉憑證 SHA-256，UI 可一鍵釘選
    case untrustedCertificate(fingerprint: String?)
    /// FTP／SFTP 需要 lftp 但找不到
    case lftpMissing
    /// 鑰匙圈沒有密碼／token（帳號剛建立或已登出）
    case missingCredential
    /// pCloud 未設定 OAuth client（設定 → 網路）
    case pcloudNotConfigured
    case notFound(String)
    case alreadyExists(String)
    /// 伺服器回報的其他錯誤（HTTP 狀態、FTP 回應碼、pCloud result）
    case server(String)

    public var errorDescription: String? {
        switch self {
        case let .authenticationFailed(detail):
            return String(localized: "Sign-in failed: \(detail)")
        case let .unreachable(detail):
            return String(localized: "Cannot reach the server: \(detail)")
        case .untrustedCertificate:
            return String(localized: "The server certificate is not trusted.")
        case .lftpMissing:
            return String(localized: "FTP and SFTP need lftp: brew install lftp")
        case .missingCredential:
            return String(localized: "No password or sign-in saved for this account.")
        case .pcloudNotConfigured:
            return String(localized: "Set the pCloud client ID and secret in Settings → Network first.")
        case let .notFound(path):
            return String(localized: "Not found: \(path)")
        case let .alreadyExists(path):
            return String(localized: "Already exists: \(path)")
        case let .server(message):
            return message
        }
    }
}
