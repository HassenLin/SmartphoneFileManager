import SFMCore
import SwiftUI

/// 網路帳號庫的可觀察狀態；持久化交給 core 的 `NetworkAccountFile`，祕密交給 `CredentialStore`（鑰匙圈）。
///
/// `revision` 每次變更遞增：AppModel 據此讓快取的 FileSource 失效（帳號改了主機、密碼、選項都要重建）。
@MainActor
@Observable
final class AccountStore {
    private(set) var library: NetworkAccountLibrary
    private(set) var revision = 0
    @ObservationIgnored private let file: NetworkAccountFile
    /// 變更通知（AppModel 用來讓快取的來源失效、重連窗格）
    @ObservationIgnored var onChange: (() -> Void)?

    init(file: NetworkAccountFile = NetworkAccountFile()) {
        self.file = file
        self.library = file.load()
    }

    var accounts: [NetworkAccount] { library.accounts }
    var defaults: ConnectionOptions.Resolved { library.defaults }

    func account(_ id: UUID?) -> NetworkAccount? { id.flatMap { library.account($0) } }
    func account(for source: SourceID?) -> NetworkAccount? { account(source?.networkAccountID) }
    func options(for account: NetworkAccount) -> ConnectionOptions.Resolved { library.options(for: account) }

    /// 新增或更新（以 id 判斷）。`password` 非 nil 時寫入鑰匙圈；主機／帳號／協定變了時搬移既有密碼
    /// （鑰匙圈以 主機＋埠＋協定＋帳號 為鍵，不搬就會「改了帳號名稱後密碼不見」）。
    func save(_ account: NetworkAccount, password: String?) throws {
        let previous = library.account(account.id)
        let carried = password ?? previous.flatMap(CredentialStore.password(for:))
        if let previous, previous.protocol != .pcloud, Self.keychainKeyChanged(previous, account) {
            CredentialStore.deletePassword(for: previous)
        }
        if let carried, !carried.isEmpty, account.protocol != .pcloud {
            CredentialStore.setPassword(carried, for: account)
        }
        try mutate { library in
            if let index = library.accounts.firstIndex(where: { $0.id == account.id }) {
                library.accounts[index] = account
            } else {
                library.accounts.append(account)
            }
        }
    }

    private static func keychainKeyChanged(_ a: NetworkAccount, _ b: NetworkAccount) -> Bool {
        a.host != b.host || a.username != b.username || a.effectivePort != b.effectivePort || a.protocol != b.protocol
            || a.useTLS != b.useTLS || (a.ftpSecurity == .none) != (b.ftpSecurity == .none)
    }

    func delete(_ account: NetworkAccount) throws {
        // 另一個帳號用同一組 主機＋帳號 時（例如複製出來的帳號），密碼還在用，不刪
        let sharesPassword = library.accounts.contains {
            $0.id != account.id && $0.protocol != .pcloud && !Self.keychainKeyChanged($0, account)
        }
        if !sharesPassword { CredentialStore.deletePassword(for: account) }
        CredentialStore.deletePCloudToken(for: account)
        try mutate { $0.accounts.removeAll { $0.id == account.id } }
    }

    /// 複製帳號（新 id、名稱加「拷貝」）；密碼共用同一筆鑰匙圈項目，pCloud token 另存一份
    func duplicate(_ account: NetworkAccount) throws -> NetworkAccount {
        var copy = account
        copy.id = UUID()
        copy.name = String(localized: "\(account.displayName) copy")
        if account.protocol == .pcloud, let token = CredentialStore.pcloudToken(for: account) {
            CredentialStore.setPCloudToken(token, for: copy)
        }
        try mutate { library in
            let index = library.accounts.firstIndex { $0.id == account.id }.map { $0 + 1 } ?? library.accounts.count
            library.accounts.insert(copy, at: index)
        }
        return copy
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        try mutate { $0.accounts.move(fromOffsets: source, toOffset: destination) }
    }

    func saveDefaults(_ defaults: ConnectionOptions.Resolved) throws {
        try mutate { $0.defaults = defaults }
    }

    func savePCloudClient(id: String, secret: String?) throws {
        if let secret { CredentialStore.setPCloudClientSecret(secret) }
        try mutate { $0.pcloudClientID = id.trimmingCharacters(in: .whitespaces) }
    }

    /// pCloud 登入成功：存 token、更新地區與 email
    func savePCloudSignIn(_ result: PCloudOAuth.Result, email: String?, for account: NetworkAccount) throws -> NetworkAccount {
        CredentialStore.setPCloudToken(result.token, for: account)
        var updated = account
        updated.pcloudRegion = result.region
        if let email { updated.username = email }
        if library.account(account.id) != nil { try save(updated, password: nil) } else { bump() }
        return updated
    }

    func signOutPCloud(_ account: NetworkAccount) {
        CredentialStore.deletePCloudToken(for: account)
        bump()
    }

    /// 只有鑰匙圈變了（例如登出）也要讓快取的來源失效
    func bump() {
        revision += 1
        onChange?()
    }

    private func mutate(_ change: (inout NetworkAccountLibrary) -> Void) throws {
        var updated = library
        change(&updated)
        try file.save(updated)
        library = updated
        bump()
    }
}
