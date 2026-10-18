import SFMCore
import SwiftUI

/// 連線選項表單，兩種用法共用同一份欄位定義：
/// - **帳號選項**（`defaults` 有值）：每列有「覆寫」勾選，未勾選＝沿用全域預設（灰字顯示預設值），可一鍵全部還原。
/// - **全域預設**（設定 → 網路，`defaults == nil`）：每欄都是具體值，沒有覆寫勾選。
///
/// `protocol` 只決定顯示哪些列（FTP 專屬的編碼、主動模式…）；全域預設時為 nil，全部顯示。
struct ConnectionOptionsForm: View {
    @Binding var options: ConnectionOptions
    let defaults: ConnectionOptions.Resolved?
    let `protocol`: NetworkProtocol?
    var ftpMode: FTPMode = .passive

    private var resolvedDefaults: ConnectionOptions.Resolved { defaults ?? .standard }

    private func shows(_ protocols: NetworkProtocol...) -> Bool {
        guard let current = self.protocol else { return true }
        return protocols.contains(current)
    }

    var body: some View {
        Form {
            Section("Connection") {
                OptionRow("Timeout (seconds)", value: $options.timeoutSeconds, fallback: resolvedDefaults.timeoutSeconds,
                          overridable: defaults != nil) { Stepper("\($0.wrappedValue)", value: $0, in: 5...600, step: 5) }
                OptionRow("Retries", value: $options.retries, fallback: resolvedDefaults.retries,
                          overridable: defaults != nil) { Stepper("\($0.wrappedValue)", value: $0, in: 0...10) }
                OptionRow("Retry delay (seconds)", value: $options.retryDelaySeconds, fallback: resolvedDefaults.retryDelaySeconds,
                          overridable: defaults != nil) { Stepper("\($0.wrappedValue)", value: $0, in: 1...120) }
                if shows(.ftp, .sftp) {
                    OptionRow("Disconnect when idle (seconds)", value: $options.idleSeconds, fallback: resolvedDefaults.idleSeconds,
                              overridable: defaults != nil) { Stepper("\($0.wrappedValue)", value: $0, in: 10...3600, step: 10) }
                }
            }
            Section {
                OptionRow("Simultaneous transfers", value: $options.parallelTransfers, fallback: resolvedDefaults.parallelTransfers,
                          overridable: defaults != nil) { Stepper("\($0.wrappedValue)", value: $0, in: 1...8) }
                OptionRow("Large file size (MB)", value: $options.largeFileThresholdMB,
                          fallback: resolvedDefaults.largeFileThresholdMB, overridable: defaults != nil) {
                    Stepper("\($0.wrappedValue)", value: $0, in: 10...10_000, step: 50)
                }
                OptionRow("Connections per large file", value: $options.maxConnections, fallback: resolvedDefaults.maxConnections,
                          overridable: defaults != nil) { Stepper("\($0.wrappedValue)", value: $0, in: 1...16) }
            } header: {
                Text("Parallel Transfers")
            } footer: {
                Text("The main executor always downloads over several connections. With 2 or more simultaneous transfers, it takes the large files and the other slots move small files one connection each. With 1, it is the only executor, so every download uses several connections. Uploads always use one connection per file. With a phone on the other side, transfers stay one at a time. FTP servers often limit connections per IP.")
                    .font(.caption)
            }
            if shows(.ftp, .sftp) {
                Section("Transfer") {
                    OptionRow("File name encoding", value: $options.ftpCharset, fallback: resolvedDefaults.ftpCharset,
                              overridable: defaults != nil) { value in
                        Picker("", selection: value) {
                            ForEach(Self.charsets, id: \.self) { Text($0.isEmpty ? String(localized: "UTF-8 (default)") : $0).tag($0) }
                        }
                        .labelsHidden()
                    }
                    if shows(.ftp) {
                        OptionRow("Server time zone (LIST)", value: $options.serverTimeZone, fallback: resolvedDefaults.serverTimeZone,
                                  overridable: defaults != nil) { TextField("UTC", text: $0) }
                        if self.protocol == nil || ftpMode == .active {
                            OptionRow("Active mode: external IP", value: $options.activeAddress,
                                      fallback: resolvedDefaults.activeAddress, overridable: defaults != nil) {
                                TextField("Automatic", text: $0)
                            }
                            OptionRow("Active mode: port range", value: $options.activePortRange,
                                      fallback: resolvedDefaults.activePortRange, overridable: defaults != nil) {
                                TextField("Any (e.g. 40000-40100)", text: $0)
                            }
                        }
                    }
                }
            }
            Section("Security") {
                if shows(.webdav, .ftp) {
                    OptionRow("Verify server certificate", value: $options.verifyCertificate,
                              fallback: resolvedDefaults.verifyCertificate, overridable: defaults != nil) {
                        Toggle("", isOn: $0).labelsHidden()
                    }
                }
                if shows(.webdav, .pcloud) {
                    OptionRow("Minimum TLS version", value: $options.minimumTLS, fallback: resolvedDefaults.minimumTLS,
                              overridable: defaults != nil) { value in
                        Picker("", selection: value) { ForEach(TLSVersion.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                    }
                }
                if shows(.ftp) {
                    Text("FTPS always uses TLS 1.2: lftp can truncate uploads over TLS 1.3.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if shows(.webdav) {
                Section("WebDAV") {
                    OptionRow("Resume uploads", value: $options.partialWrite, fallback: resolvedDefaults.partialWrite,
                              overridable: defaults != nil) { value in
                        Picker("", selection: value) {
                            Text("Detect partial-write support").tag(PartialWriteMode.auto)
                            Text("Always re-upload whole file").tag(PartialWriteMode.off)
                        }
                        .labelsHidden()
                    }
                }
            }
            if shows(.ftp, .sftp) {
                Section {
                    OptionRow("Extra lftp settings", value: $options.extraLftpCommands,
                              fallback: resolvedDefaults.extraLftpCommands, overridable: defaults != nil) {
                        TextEditor(text: $0).font(.system(.body, design: .monospaced)).frame(height: 60)
                    }
                    let rejected = ConnectionOptions.rejectedLftpLines(options.extraLftpCommands ?? resolvedDefaults.extraLftpCommands)
                    if !rejected.isEmpty {
                        Label(String(localized: "Ignored (only “set …” lines are allowed): \(rejected.joined(separator: ", "))"),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("One “set name value” per line, e.g. set ftp:use-feat no").font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 常見的伺服器檔名編碼（舊 NAS／中文 Windows FTP 常是 Big5 或 GBK）
    static let charsets = ["", "Big5", "GBK", "GB18030", "Shift_JIS", "EUC-JP", "EUC-KR", "ISO-8859-1", "Windows-1252"]
}

/// 一列選項：標題＋（帳號模式時）覆寫勾選＋編輯器。未覆寫時編輯器停用並顯示預設值。
private struct OptionRow<Value: Equatable, Editor: View>: View {
    let title: LocalizedStringKey
    @Binding var value: Value?
    let fallback: Value
    let overridable: Bool
    @ViewBuilder let editor: (Binding<Value>) -> Editor

    init(_ title: LocalizedStringKey, value: Binding<Value?>, fallback: Value, overridable: Bool,
         @ViewBuilder editor: @escaping (Binding<Value>) -> Editor) {
        self.title = title
        self._value = value
        self.fallback = fallback
        self.overridable = overridable
        self.editor = editor
    }

    var body: some View {
        LabeledContent {
            HStack {
                editor(Binding(get: { value ?? fallback }, set: { value = $0 }))
                    .disabled(overridable && value == nil)
                if overridable {
                    Toggle("Custom", isOn: Binding(get: { value != nil }, set: { value = $0 ? fallback : nil }))
                        .toggleStyle(.checkbox)
                        .help("Off = use the default from Settings → Network")
                }
            }
        } label: {
            Text(title)
        }
    }
}

/// 帳號的「選項」視窗（帳號設定的「選項…」按鈕開啟）
struct AccountOptionsSheet: View {
    @Binding var account: NetworkAccount
    let defaults: ConnectionOptions.Resolved
    @Environment(\.dismiss) private var dismiss
    @State private var hostKey: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Options — \(account.displayName)").font(.title3.bold())
                Spacer()
                Button("Restore All Defaults") { account.options = ConnectionOptions() }
                    .disabled(!account.options.hasOverrides)
            }
            .padding(16)
            ConnectionOptionsForm(options: $account.options, defaults: defaults, protocol: account.protocol,
                                  ftpMode: account.ftpMode)
            if account.protocol == .webdav || account.protocol == .sftp { pinnedSection }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 620)
        .task(id: account.host) {
            if account.protocol == .sftp {
                hostKey = await SFTPHostKeys.fingerprint(host: account.host, port: account.effectivePort)
            }
        }
    }

    /// 已信任的身分：WebDAV 釘選的憑證指紋、SFTP 記住的主機金鑰
    @ViewBuilder
    private var pinnedSection: some View {
        Form {
            Section("Trusted identity") {
                if account.protocol == .webdav {
                    LabeledContent("Pinned certificate (SHA-256)") {
                        HStack {
                            Text(account.pinnedCertSHA256.isEmpty ? String(localized: "None — system trust") : account.pinnedCertSHA256)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .lineLimit(2).truncationMode(.middle)
                            if !account.pinnedCertSHA256.isEmpty {
                                Button("Clear") { account.pinnedCertSHA256 = "" }
                            }
                        }
                    }
                } else {
                    LabeledContent("Host key") {
                        HStack {
                            Text(hostKey ?? String(localized: "Not yet known (remembered on first connection)"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            if hostKey != nil {
                                Button("Forget") {
                                    Task {
                                        try? await SFTPHostKeys.reset(host: account.host, port: account.effectivePort)
                                        hostKey = await SFTPHostKeys.fingerprint(host: account.host, port: account.effectivePort)
                                    }
                                }
                                .help("Use after the server was reinstalled or its key changed")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 100)
    }
}
