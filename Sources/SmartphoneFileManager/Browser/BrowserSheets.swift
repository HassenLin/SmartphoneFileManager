import SFMCore
import SwiftUI

/// 單行輸入對話框（新資料夾、改名、書籤名稱）
struct TextInputSheet: View {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    @State var text: String
    var multilineContent: Binding<String>?
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            if let multilineContent {
                Text("Initial content (optional)").font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: multilineContent)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 160)
                    .border(Color.secondary.opacity(0.3))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func confirm() {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        dismiss()
        onConfirm(value)
    }
}

/// 新增檔案（含初始內容）
struct NewFileSheet: View {
    let onConfirm: (String, String) -> Void
    @State private var content = ""

    var body: some View {
        TextInputSheet(title: "New File", prompt: "File name", confirmTitle: "Create", text: "",
                       multilineContent: $content) { name in onConfirm(name, content) }
    }
}

/// 權限設定：九個核取方塊 ⇄ 八進位，兩邊同步（原版 ChangePermissionsDialog）
struct PermissionsSheet: View {
    let file: FileItem
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bits: [Bool]

    init(file: FileItem, onConfirm: @escaping (String) -> Void) {
        self.file = file
        self.onConfirm = onConfirm
        // 從 `-rwxr-x---` 取後 9 個字元還原初始勾選
        let chars = Array(file.permissions.suffix(9))
        _bits = State(initialValue: (0..<9).map { index in chars.count == 9 && chars[index] != "-" })
    }

    private var octal: String {
        stride(from: 0, to: 9, by: 3).map { start in
            String((bits[start] ? 4 : 0) + (bits[start + 1] ? 2 : 0) + (bits[start + 2] ? 1 : 0))
        }.joined()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.headline)
            Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Read"); Text("Write"); Text("Execute")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(Array([String(localized: "Owner"), String(localized: "Group"), String(localized: "Others")].enumerated()), id: \.offset) { row, title in
                    GridRow {
                        Text(title)
                        ForEach(0..<3, id: \.self) { column in
                            Toggle("", isOn: $bits[row * 3 + column]).labelsHidden()
                        }
                    }
                }
            }
            HStack {
                Text("chmod \(octal)").font(.system(.body, design: .monospaced))
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    dismiss()
                    onConfirm(octal)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// 遞迴搜尋（原版 SearchDialog：從目前目錄往下 4 層）
struct SearchSheet: View {
    let app: AppModel
    let side: PaneSide
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [FileItem] = []
    @State private var searching = false
    @State private var searched = false
    @State private var selection: FileItem.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search in \(app.pane(side).path)").font(.headline)
            HStack {
                TextField("File name contains…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search", action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            List(results, selection: $selection) { file in
                HStack {
                    FileNameCell(item: file)
                    Spacer()
                    Text(RemotePath.parent(of: file.path)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                .tag(file.id)
            }
            .contextMenu(forSelectionType: FileItem.ID.self) { _ in } primaryAction: { ids in
                if let file = results.first(where: { ids.contains($0.id) }) { reveal(file) }
            }
            .overlay {
                if searching { ProgressView() }
                else if searched && results.isEmpty { Text("No results").foregroundStyle(.secondary) }
            }
            HStack {
                Text("Double-click a result to show it in its folder.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 620, height: 480)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        Task {
            defer { searching = false; searched = true }
            do {
                guard let android = app.pane(side).androidSource else { return }
                results = try await android.search(in: app.pane(side).path, query: text)
            } catch {
                app.toasts.error(error)
            }
        }
    }

    private func reveal(_ file: FileItem) {
        dismiss()
        if file.isDirectory {
            app.pane(side).navigate(to: file.path)
        } else {
            app.pane(side).navigate(to: RemotePath.parent(of: file.path), highlight: file.path)
        }
    }
}

/// 傳送文字到裝置剪貼簿（原版 ClipboardDialog）
struct ClipboardSheet: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = NSPasteboard.general.string(forType: .string) ?? ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send to Device Clipboard").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 180)
                .border(Color.secondary.opacity(0.3))
            HStack {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func send() {
        guard let connection = app.devices.connection else { return app.toasts.error(AdbError.noDevice) }
        sending = true
        Task {
            defer { sending = false }
            do {
                try await ClipboardService(device: connection).push(text: text)
                app.toasts.success(String(localized: "Sent to device clipboard"))
                dismiss()
            } catch {
                app.toasts.error(error)
            }
        }
    }
}

/// 無線偵錯：配對、連線、把 USB 裝置切到 TCP/IP 模式（原版 DeviceSelection 的連線區塊）
struct ConnectSheet: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "5555"
    @State private var pairingPort = ""
    @State private var pairingCode = ""
    @State private var log = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wireless Connection").font(.headline)
            Form {
                TextField("IP address", text: $host)
                TextField("Port", text: $port)
                Section {
                    TextField("Pairing port", text: $pairingPort)
                    TextField("Pairing code", text: $pairingCode)
                } header: {
                    Text("Android 11+: Developer options → Wireless debugging → Pair device with pairing code")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .frame(height: 230)

            HStack {
                Button("Pair") { run { try await AdbClient.current.pair(host: host, port: pairingPort, code: pairingCode) } }
                    .disabled(host.isEmpty || pairingPort.isEmpty || pairingCode.isEmpty)
                Button("Connect") { run { try await AdbClient.current.connect(host: host, port: port) } }
                    .disabled(host.isEmpty)
                    .keyboardShortcut(.defaultAction)
                Button("Enable TCP/IP on USB Device") { enableTcpip() }
                    .disabled(app.devices.connection == nil || app.devices.selectedDevice?.isWireless == true)
                    .help("Runs adb tcpip on the selected USB device and fills in its Wi-Fi IP address.")
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            ScrollView {
                Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func run(_ action: @escaping @MainActor () async throws -> String) {
        working = true
        Task {
            defer { working = false }
            do {
                log += try await action() + "\n"
                await app.devices.refresh()
            } catch {
                log += error.localizedDescription + "\n"
            }
        }
    }

    /// 查出 USB 裝置的 wlan0 IP，再 `adb tcpip`
    private func enableTcpip() {
        guard let connection = app.devices.connection else { return }
        let targetPort = port.isEmpty ? "5555" : port
        run {
            let route = try await connection.shell("ip route")
            if let line = route.first(where: { $0.contains("wlan0") }),
               let ip = line.firstMatch(of: /src\s+(\d{1,3}(?:\.\d{1,3}){3})/)?.1 ?? line.firstMatch(of: /(\d{1,3}(?:\.\d{1,3}){3})\s*$/)?.1 {
                host = String(ip)
            }
            let output = try await connection.client.run(["-s", connection.serial, "tcpip", targetPort], timeout: .seconds(15))
            return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
