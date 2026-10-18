import Foundation
import Security

/// 網路帳號的祕密存於登入鑰匙圈（由 nas_webdav 的 KeychainStore 一般化）。
///
/// - WebDAV／FTP／SFTP 密碼：「網際網路密碼」（kSecClassInternetPassword），以 主機＋埠＋協定＋帳號 為鍵——
///   在「鑰匙圈存取」以該伺服器顯示，也能沿用 Finder「連接伺服器」已存的同一組密碼。
/// - pCloud access token 與 OAuth client secret：「一般密碼」（kSecClassGenericPassword），以帳號 id 為鍵。
public enum CredentialStore {
    static let service = "idv.hassen.smartphonefilemanager"

    // MARK: 密碼（WebDAV／FTP／SFTP）

    private static func protocolAttribute(_ account: NetworkAccount) -> CFString {
        switch account.protocol {
        case .webdav: return account.useTLS ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP
        case .ftp: return account.ftpSecurity == .none ? kSecAttrProtocolFTP : kSecAttrProtocolFTPS
        case .sftp: return kSecAttrProtocolSSH
        case .pcloud: return kSecAttrProtocolHTTPS
        }
    }

    private static func passwordQuery(_ account: NetworkAccount) -> [String: Any]? {
        let host = account.host.trimmingCharacters(in: .whitespaces)
        guard account.protocol != .pcloud, !host.isEmpty, !account.username.isEmpty else { return nil }
        return [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: protocolAttribute(account),
            kSecAttrPort as String: account.effectivePort,
            kSecAttrAccount as String: account.username,
        ]
    }

    public static func password(for account: NetworkAccount) -> String? {
        passwordQuery(account).flatMap(read)
    }

    @discardableResult
    public static func setPassword(_ password: String, for account: NetworkAccount) -> Bool {
        guard let query = passwordQuery(account) else { return false }
        return write(Data(password.utf8), query: query, label: "\(account.host) (Smartphone File Manager)")
    }

    public static func deletePassword(for account: NetworkAccount) {
        if let query = passwordQuery(account) { SecItemDelete(query as CFDictionary) }
    }

    // MARK: 一般祕密（pCloud token、OAuth client secret）

    private static func genericQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func tokenKey(_ account: NetworkAccount) -> String { "pcloud-token:\(account.id.uuidString)" }
    static let clientSecretKey = "pcloud-client-secret"

    public static func pcloudToken(for account: NetworkAccount) -> String? { read(genericQuery(tokenKey(account))) }

    @discardableResult
    public static func setPCloudToken(_ token: String, for account: NetworkAccount) -> Bool {
        write(Data(token.utf8), query: genericQuery(tokenKey(account)), label: "pCloud (Smartphone File Manager)")
    }

    public static func deletePCloudToken(for account: NetworkAccount) {
        SecItemDelete(genericQuery(tokenKey(account)) as CFDictionary)
    }

    public static var pcloudClientSecret: String? { read(genericQuery(clientSecretKey)) }

    @discardableResult
    public static func setPCloudClientSecret(_ secret: String) -> Bool {
        if secret.isEmpty {
            SecItemDelete(genericQuery(clientSecretKey) as CFDictionary)
            return true
        }
        return write(Data(secret.utf8), query: genericQuery(clientSecretKey), label: "pCloud OAuth client (Smartphone File Manager)")
    }

    /// 刪除帳號時清掉它的所有祕密
    public static func deleteAll(for account: NetworkAccount) {
        deletePassword(for: account)
        deletePCloudToken(for: account)
    }

    // MARK: 共用

    private static func read(_ query: [String: Any]) -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ data: Data, query: [String: Any], label: String) -> Bool {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
