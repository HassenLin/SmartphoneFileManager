import Foundation

/// 網路帳號庫：帳號清單（順序＝來源選單順序）＋全域預設選項＋pCloud OAuth app 設定。
public struct NetworkAccountLibrary: Codable, Hashable, Sendable {
    public var accounts: [NetworkAccount] = []
    /// 帳號選項為 nil 的欄位沿用這裡（設定 → 網路）
    public var defaults = ConnectionOptions.Resolved()
    /// 使用者在 pCloud 開發者頁註冊的 app（OAuth2 client）；secret 存鑰匙圈（`CredentialStore.pcloudClientSecret`）
    public var pcloudClientID = ""

    public init(accounts: [NetworkAccount] = []) {
        self.accounts = accounts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([NetworkAccount].self, forKey: .accounts) ?? []
        defaults = try c.decodeIfPresent(ConnectionOptions.Resolved.self, forKey: .defaults) ?? .standard
        pcloudClientID = try c.decodeIfPresent(String.self, forKey: .pcloudClientID) ?? ""
    }

    public func account(_ id: UUID) -> NetworkAccount? { accounts.first { $0.id == id } }

    /// 帳號的有效選項（帳號覆寫＋全域預設）
    public func options(for account: NetworkAccount) -> ConnectionOptions.Resolved {
        account.options.resolved(defaults: defaults)
    }
}

/// 帳號庫讀寫：`Application Support/SmartphoneFileManager/accounts.json`（不含密碼）。
public struct NetworkAccountFile: Sendable {
    public let url: URL

    public init(url: URL = QueueStore.standard.directory.appendingPathComponent("accounts.json")) {
        self.url = url
    }

    public func load() -> NetworkAccountLibrary {
        guard let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(NetworkAccountLibrary.self, from: data) else {
            return NetworkAccountLibrary()
        }
        return library
    }

    public func save(_ library: NetworkAccountLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}
