import SFMCore
import SwiftUI

/// 開啟帳號視窗時要做的事（來源選單「新增網路帳號…」、窗格錯誤畫面「編輯帳號…」）
enum AccountWindowRequest: Equatable {
    case select(UUID)
    case new(NetworkProtocol)
}

/// 網路帳號視窗：左邊帳號清單（表格）、右邊帳號設定。
///
/// 清單順序＝窗格來源選單的順序（上移／下移調整）。刪除時說明哪些地方還在用；
/// 有未完成的工作引用時不可刪（否則佇列裡的工作再也找不到來源）。
struct AccountListWindow: View {
    static let windowID = "accounts"

    let app: AppModel
    @State private var selection: UUID?
    /// 新增中、尚未儲存的帳號（存檔前不在帳號庫）
    @State private var newDraft: NetworkAccount?
    @State private var revealed: Set<UUID> = []
    @State private var pendingDelete: NetworkAccount?
    @State private var errorMessage: String?

    private var store: AccountStore { app.accounts }
    private var selected: NetworkAccount? { store.account(selection) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                table
                Divider()
                bottomBar
            }
            .frame(minWidth: 600, maxHeight: .infinity)
            detail
                .frame(minWidth: 420, idealWidth: 460, maxHeight: .infinity)
        }
        .frame(minHeight: 480)
        .onAppear { consume(app.accountWindowRequest) }
        .onChange(of: app.accountWindowRequest) { _, request in consume(request) }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { account in
            Button("Delete", role: .destructive) { delete(account) }
        } message: { account in
            Text(deleteMessage(account))
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 清單

    private var table: some View {
        Table(store.accounts, selection: Binding(get: { selection }, set: { select($0) })) {
            TableColumn("Name") { account in
                Label(account.displayName, systemImage: AppModel.symbol(for: account.protocol))
            }
            .width(min: 100, ideal: 130)
            TableColumn("Protocol") { Text($0.protocolLabel) }.width(min: 50, ideal: 70)
            TableColumn("Server") { Text($0.serverLabel).lineLimit(1).truncationMode(.middle) }.width(min: 80, ideal: 120)
            TableColumn("Account") { Text($0.username) }.width(min: 60, ideal: 80)
            TableColumn("Password") { account in passwordCell(account) }.width(min: 70, ideal: 100)
            TableColumn("Security") { account in
                if account.isEncrypted {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Encrypted")
                } else {
                    Label("Not encrypted", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .labelStyle(.iconOnly).help("Not encrypted")
                }
            }
            .width(min: 36, ideal: 40)
            TableColumn("In Use") { account in
                let usage = app.usage(of: account)
                Text(usage.total == 0 ? "—" : "\(usage.total)").help(usageText(usage))
            }
            .width(min: 36, ideal: 44)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let account = store.account(id) {
                Button("Open in Left Pane") { open(account, .left) }
                Button("Open in Right Pane") { open(account, .right) }
                Divider()
                Button("Duplicate") { duplicate(account) }
                Button("Delete…") { pendingDelete = account }
            }
        } primaryAction: { ids in
            // 雙擊：在最後操作的窗格開啟
            if let id = ids.first, let account = store.account(id) { open(account, app.activeSide) }
        }
    }

    @ViewBuilder
    private func passwordCell(_ account: NetworkAccount) -> some View {
        switch account.protocol {
        case .pcloud:
            Text(CredentialStore.pcloudToken(for: account) == nil ? String(localized: "Not signed in") : String(localized: "Signed in"))
                .foregroundStyle(.secondary)
        case .sftp where account.sftpAuth == .key:
            Text("Key").foregroundStyle(.secondary)
        default:
            HStack(spacing: 4) {
                if revealed.contains(account.id) {
                    Text(CredentialStore.password(for: account) ?? String(localized: "None")).textSelection(.enabled)
                } else {
                    Text(CredentialStore.password(for: account) == nil ? String(localized: "None") : "••••••••")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if revealed.contains(account.id) { revealed.remove(account.id) } else { revealed.insert(account.id) }
                } label: {
                    Image(systemName: revealed.contains(account.id) ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed.contains(account.id) ? "Hide password" : "Show password")
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(NetworkProtocol.allCases) { networkProtocol in
                    Button(networkProtocol.title) { startNew(networkProtocol) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add Account")
            Button { if let selected { pendingDelete = selected } } label: { Image(systemName: "minus") }
                .disabled(selected == nil)
                .help("Delete Account")
            Button { if let selected { duplicate(selected) } } label: { Image(systemName: "plus.square.on.square") }
                .disabled(selected == nil)
                .help("Duplicate")
            Divider().frame(height: 16)
            Button { move(by: -1) } label: { Image(systemName: "arrow.up") }
                .disabled(!canMove(by: -1))
                .help("Move Up (order in the source menu)")
            Button { move(by: 1) } label: { Image(systemName: "arrow.down") }
                .disabled(!canMove(by: 1))
                .help("Move Down (order in the source menu)")
            Spacer()
            if let selected {
                Button("Open in Left Pane") { open(selected, .left) }
                Button("Open in Right Pane") { open(selected, .right) }
            }
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    @ViewBuilder
    private var detail: some View {
        if let newDraft {
            AccountEditorView(app: app, account: newDraft, isNew: true, onSaved: { saved in
                self.newDraft = nil
                selection = saved.id
            }, onCancelNew: {
                // 新增時若已登入 pCloud，取消要清掉 token，不留孤兒祕密
                CredentialStore.deletePCloudToken(for: newDraft)
                self.newDraft = nil
            })
            .id(newDraft.id)
        } else if let selected {
            AccountEditorView(app: app, account: selected, isNew: false)
                .id("\(selected.id)-\(store.revision)")
        } else {
            ContentUnavailableView {
                Label("No Account Selected", systemImage: "network")
            } description: {
                Text("Add a WebDAV, FTP, SFTP or pCloud account with the + button.")
            } actions: {
                Menu("Add Account") {
                    ForEach(NetworkProtocol.allCases) { networkProtocol in
                        Button(networkProtocol.title) { startNew(networkProtocol) }
                    }
                }
                .fixedSize()
            }
        }
    }

    // MARK: 動作

    private func consume(_ request: AccountWindowRequest?) {
        switch request {
        case let .select(id): select(id)
        case let .new(networkProtocol): startNew(networkProtocol)
        case nil: break
        }
        app.accountWindowRequest = nil
    }

    private func select(_ id: UUID?) {
        newDraft = nil
        selection = id
    }

    private func startNew(_ networkProtocol: NetworkProtocol) {
        selection = nil
        var account = NetworkAccount(protocol: networkProtocol)
        if networkProtocol == .ftp { account.ftpSecurity = .explicit }
        newDraft = account
    }

    private func open(_ account: NetworkAccount, _ side: PaneSide) {
        app.selectSource(account.sourceID, for: side)
    }

    private func duplicate(_ account: NetworkAccount) {
        do { selection = try store.duplicate(account).id } catch { errorMessage = error.localizedDescription }
    }

    private func canMove(by offset: Int) -> Bool {
        guard let index = store.accounts.firstIndex(where: { $0.id == selection }) else { return false }
        return store.accounts.indices.contains(index + offset)
    }

    private func move(by offset: Int) {
        guard let index = store.accounts.firstIndex(where: { $0.id == selection }) else { return }
        do {
            try store.move(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? index + 2 : index - 1)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var deleteTitle: String {
        String(localized: "Delete “\(pendingDelete?.displayName ?? "")”?")
    }

    private func usageText(_ usage: AppModel.AccountUsage) -> String {
        var parts: [String] = []
        if usage.panes > 0 { parts.append(String(localized: "\(usage.panes) pane(s)")) }
        if usage.bookmarks > 0 { parts.append(String(localized: "\(usage.bookmarks) bookmark(s)")) }
        if usage.syncProjects > 0 { parts.append(String(localized: "\(usage.syncProjects) sync project(s)")) }
        if usage.pendingJobs > 0 { parts.append(String(localized: "\(usage.pendingJobs) unfinished job(s)")) }
        return parts.isEmpty ? String(localized: "Not used") : parts.joined(separator: String(localized: ", "))
    }

    private func deleteMessage(_ account: NetworkAccount) -> String {
        let usage = app.usage(of: account)
        if usage.total == 0 { return String(localized: "The saved password or sign-in is removed from the keychain.") }
        return String(localized: "Still used by: \(usageText(usage)). Those bookmarks and sync projects will no longer open.")
    }

    private func delete(_ account: NetworkAccount) {
        let usage = app.usage(of: account)
        guard usage.pendingJobs == 0 else {
            errorMessage = String(localized: "Finish or remove the account’s unfinished jobs in the task panel first.")
            return
        }
        do {
            try store.delete(account)
            if selection == account.id { selection = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
