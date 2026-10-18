import AppKit
import SFMCore
import SwiftUI

/// 帳號設定（帳號清單右側的詳細面板）：基本連線欄位＋測試連線＋pCloud 登入；進階選項在「選項…」視窗。
///
/// 編輯的是草稿（`draft`），按「儲存」才寫入帳號庫與鑰匙圈；切換到別的帳號時未儲存的變更會被捨棄
/// （清單以 `.id(account.id)` 重建本視圖）。
struct AccountEditorView: View {
    let app: AppModel
    /// 帳號庫中的原始帳號；新帳號尚未儲存時不在帳號庫內
    let original: NetworkAccount
    let isNew: Bool
    var onSaved: (NetworkAccount) -> Void = { _ in }
    var onCancelNew: () -> Void = {}

    @State private var draft: NetworkAccount
    @State private var password = ""
    @State private var savedPassword = ""
    @State private var showPassword = false
    @State private var showOptions = false
    @State private var test: TestState = .idle
    @State private var signingIn = false
    @State private var signedInToken = false
    /// pCloud 帳號啟用兩步驟驗證：等使用者輸入驗證碼
    @State private var twoFactor: PCloudLogin.TwoFactorRequired?
    @State private var twoFactorCode = ""
    @State private var errorMessage: String?

    enum TestState: Equatable {
        case idle, running
        case success(String)
        case failure(NetworkError)
    }

    init(app: AppModel, account: NetworkAccount, isNew: Bool,
         onSaved: @escaping (NetworkAccount) -> Void = { _ in }, onCancelNew: @escaping () -> Void = {}) {
        self.app = app
        self.original = account
        self.isNew = isNew
        self.onSaved = onSaved
        self.onCancelNew = onCancelNew
        _draft = State(initialValue: account)
    }

    private var isDirty: Bool { isNew || draft != original || password != savedPassword }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text(draft.displayName))
                    Picker("Protocol", selection: $draft.protocol) {
                        ForEach(NetworkProtocol.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!isNew)
                }
                if draft.protocol == .pcloud { pcloudSection } else { serverSection }
                if !draft.isEncrypted {
                    Label("Not encrypted: the password and files are sent in clear text. Use only on a trusted network.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                testSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Options…") { showOptions = true }
                if draft.options.hasOverrides {
                    Text("Custom options").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isNew {
                    Button("Cancel") { onCancelNew() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Revert") { revert() }.disabled(!isDirty)
                }
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty || draft.validationError() != nil)
            }
            .padding(12)
        }
        .sheet(isPresented: $showOptions) {
            AccountOptionsSheet(account: $draft, defaults: app.accounts.defaults)
        }
        .alert("Cannot Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: loadSecrets)
        .onChange(of: draft.protocol) { _, _ in test = .idle }
    }

    // MARK: 伺服器欄位

    @ViewBuilder
    private var serverSection: some View {
        Section("Server") {
            TextField("Host", text: $draft.host, prompt: Text("nas.local or 192.168.1.10"))
            TextField("Port", value: $draft.port, format: .number.grouping(.never), prompt: Text("\(draft.defaultPort)"))
            switch draft.protocol {
            case .webdav:
                Picker("Connection", selection: $draft.useTLS) {
                    Text("HTTPS (encrypted)").tag(true)
                    Text("HTTP (not encrypted)").tag(false)
                }
            case .ftp:
                Picker("Encryption", selection: $draft.ftpSecurity) {
                    Text("FTPS explicit (AUTH TLS)").tag(FTPSecurity.explicit)
                    Text("FTPS implicit (port 990)").tag(FTPSecurity.implicit)
                    Text("None (plain FTP)").tag(FTPSecurity.none)
                }
                Picker("Data connection", selection: $draft.ftpMode) {
                    Text("Passive").tag(FTPMode.passive)
                    Text("Active").tag(FTPMode.active)
                }
                .pickerStyle(.segmented)
                if draft.ftpMode == .active {
                    Text("Active mode needs the server to connect back to this Mac. Behind NAT, set the external IP and port range in Options.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
            TextField("Start folder", text: $draft.rootPath, prompt: Text("/"))
        }
        Section("Sign-in") {
            TextField("User name", text: $draft.username)
            if draft.protocol == .sftp {
                Picker("Authentication", selection: $draft.sftpAuth) {
                    Text("Password").tag(SFTPAuth.password)
                    Text("Private key").tag(SFTPAuth.key)
                }
                .pickerStyle(.segmented)
            }
            if draft.protocol == .sftp && draft.sftpAuth == .key {
                LabeledContent("Private key") {
                    HStack {
                        Text(draft.sftpKeyPath.isEmpty ? String(localized: "None") : draft.sftpKeyPath)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseKey() }
                    }
                }
                Text("Keys with a passphrase must be added to ssh-agent first (ssh-add --apple-use-keychain).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Password") {
                    HStack {
                        if showPassword { TextField("", text: $password).labelsHidden() }
                        else { SecureField("", text: $password).labelsHidden() }
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                            .help(showPassword ? "Hide password" : "Show password")
                    }
                }
                Text("Saved in the login keychain.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: pCloud

    @ViewBuilder
    private var pcloudSection: some View {
        Section("pCloud") {
            Picker("Data region", selection: $draft.pcloudRegion) {
                Text("United States").tag(PCloudRegion.us)
                Text("Europe").tag(PCloudRegion.eu)
            }
            .pickerStyle(.segmented)
            Text("Set automatically when you sign in (each pCloud account lives in one region).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Start folder", text: $draft.rootPath, prompt: Text("/"))
        }
        Section("Sign-in") {
            if signedInToken {
                LabeledContent("Account") {
                    HStack {
                        Label(draft.username.isEmpty ? String(localized: "Signed in") : draft.username,
                              systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Sign Out") {
                            app.accounts.signOutPCloud(draft)
                            signedInToken = false
                            test = .idle
                        }
                    }
                }
            } else if let pending = twoFactor {
                TextField("Verification code", text: $twoFactorCode, prompt: Text("123456"))
                Text("Enter the code from your authenticator app or text message.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Verify") { verifyTwoFactor(pending) }
                        .disabled(signingIn || twoFactorCode.filter(\.isNumber).isEmpty)
                    Button("Cancel") { twoFactor = nil; twoFactorCode = "" }
                    if signingIn { ProgressView().controlSize(.small) }
                }
            } else {
                TextField("Email", text: $draft.username)
                SecureField("Password", text: $password)
                HStack {
                    Button("Sign In") { signInWithPassword() }
                        .disabled(signingIn || draft.username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                    if !app.accounts.library.pcloudClientID.isEmpty {
                        Button("Sign In with Browser…") { signIn() }.disabled(signingIn)
                    }
                    if signingIn { ProgressView().controlSize(.small) }
                }
                Text("The password is only used to sign in; just the sign-in token is kept in the login keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 測試連線

    @ViewBuilder
    private var testSection: some View {
        Section {
            HStack {
                Button("Test Connection") { runTest() }
                    .disabled(test == .running || draft.validationError() != nil)
                switch test {
                case .idle: EmptyView()
                case .running: ProgressView().controlSize(.small)
                case let .success(message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case let .failure(error):
                    Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        .lineLimit(3).textSelection(.enabled)
                }
            }
            if case let .failure(.untrustedCertificate(fingerprint)) = test { trustActions(fingerprint) }
            if case .failure(.lftpMissing) = test {
                Button("Setup Guide…") { app.sheet = .setupGuide(.network) }
            }
            if let issue = draft.validationError() {
                Text(issue).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 憑證不受信任：WebDAV 可釘選看到的 SHA-256；FTPS（lftp 只回報 SHA-1，無法釘選）可改為不驗證
    @ViewBuilder
    private func trustActions(_ fingerprint: String?) -> some View {
        if draft.protocol == .webdav, let fingerprint, fingerprint.count == 64 {
            VStack(alignment: .leading, spacing: 4) {
                Text("SHA-256: \(fingerprint)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Trust This Certificate") {
                    draft.pinnedCertSHA256 = fingerprint
                    runTest()
                }
                Text("Only trust it if the fingerprint matches the one shown on your server (for example DSM → Security → Certificate).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if draft.protocol == .ftp {
            VStack(alignment: .leading, spacing: 4) {
                if let fingerprint {
                    Text("Fingerprint: \(fingerprint)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Button("Don’t Verify the Certificate for This Account") {
                    draft.options.verifyCertificate = false
                    runTest()
                }
            }
        }
    }

    // MARK: 動作

    private func loadSecrets() {
        switch original.protocol {
        case .pcloud:
            signedInToken = CredentialStore.pcloudToken(for: original) != nil
        default:
            savedPassword = isNew ? "" : (CredentialStore.password(for: original) ?? "")
            password = savedPassword
        }
    }

    private func revert() {
        draft = original
        password = savedPassword
        test = .idle
    }

    private var secretForTest: String? {
        switch draft.protocol {
        case .pcloud: return CredentialStore.pcloudToken(for: draft)
        case .sftp where draft.sftpAuth == .key: return ""
        default: return password
        }
    }

    private func runTest() {
        let account = draft
        let options = app.accounts.options(for: account)
        guard let secret = secretForTest else { test = .failure(.missingCredential); return }
        test = .running
        Task {
            do {
                let source = try NetworkSourceFactory.make(account, options: options, secret: secret)
                let count = try await NetworkSourceFactory.test(source)
                test = .success(String(localized: "Connected — \(count) items in \(source.homePath)"))
            } catch let error as NetworkError {
                test = .failure(error)
            } catch is CancellationError {
                test = .idle
            } catch {
                test = .failure(.server(error.localizedDescription))
            }
        }
    }

    /// 帳號密碼登入（不需註冊 pCloud App）；密碼只用來換 token，不存
    private func signInWithPassword() {
        let email = draft.username, secret = password, region = draft.pcloudRegion
        runSignIn {
            do {
                return try await PCloudLogin.signIn(email: email, password: secret, preferredRegion: region)
            } catch let pending as PCloudLogin.TwoFactorRequired {
                twoFactor = pending
                return nil
            }
        }
    }

    private func verifyTwoFactor(_ pending: PCloudLogin.TwoFactorRequired) {
        let code = twoFactorCode
        runSignIn { try await PCloudLogin.verify(pending, code: code) }
    }

    /// 瀏覽器 OAuth 登入（選用：設定 → 網路 填了 client ID 才顯示）
    private func signIn() {
        let clientID = app.accounts.library.pcloudClientID
        let secret = CredentialStore.pcloudClientSecret ?? ""
        let region = draft.pcloudRegion
        let options = app.accounts.options(for: draft)
        runSignIn {
            let session = try await PCloudOAuth.signIn(clientID: clientID, clientSecret: secret, preferredRegion: region) { url in
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
            let email = try? await NetworkSourceFactory.pcloudEmail(token: session.token, region: session.region, options: options)
            return PCloudSession(token: session.token, region: session.region, email: email)
        }
    }

    /// 登入共用的收尾：存 token、更新地區與 email、顯示結果。`work` 回傳 nil＝尚未完成（等兩步驟驗證碼）
    private func runSignIn(_ work: @escaping @MainActor () async throws -> PCloudSession?) {
        let account = draft
        signingIn = true
        test = .idle
        Task {
            defer { signingIn = false }
            do {
                guard let session = try await work() else { return }
                let changedRegion = session.region != account.pcloudRegion
                let updated = try app.accounts.savePCloudSignIn(session, for: account)
                draft.pcloudRegion = updated.pcloudRegion
                draft.username = updated.username
                password = savedPassword
                twoFactor = nil
                twoFactorCode = ""
                signedInToken = true
                test = .success(changedRegion
                    ? String(localized: "Signed in — region set to \(session.region == .eu ? String(localized: "Europe") : String(localized: "United States")) for this account")
                    : String(localized: "Signed in"))
            } catch let error as NetworkError {
                test = .failure(error)
            } catch {
                test = .failure(.server(error.localizedDescription))
            }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { draft.sftpKeyPath = url.path }
    }

    private func save() {
        if let issue = draft.validationError() { errorMessage = issue; return }
        var account = draft
        account.host = account.host.trimmingCharacters(in: .whitespaces)
        if account.port == account.defaultPort { account.port = nil }
        do {
            let needsPassword = account.protocol != .pcloud && !(account.protocol == .sftp && account.sftpAuth == .key)
            try app.accounts.save(account, password: needsPassword && password != savedPassword ? password : nil)
            savedPassword = password
            onSaved(account)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
