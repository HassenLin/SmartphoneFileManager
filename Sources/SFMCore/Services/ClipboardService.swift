import Foundation

/// 寫入 Android 系統剪貼簿。
///
/// 硬體／系統背景：Android 的 `cmd clipboard` 在 shell 下沒有實作，所以原版附了一個
/// 極小的 dex（`tools/clipboard-helper`，Java 原始碼在原專案）以 `app_process` 用 shell UID
/// 執行，透過反射呼叫 `IClipboard.setPrimaryClip`。這裡沿用同一個 dex（base64，
/// 由 make-app.sh 放進 `Contents/Resources/bin/`）。
public struct ClipboardService: Sendable {
    public let device: DeviceConnection

    static let helperClass = "top.wkbin.clipboard.ClipboardHelper"
    static let successMarker = "CLIPBOARD_SET_OK"

    public init(device: DeviceConnection) {
        self.device = device
    }

    static func loadHelper() throws -> Data {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/clipboard-helper.dex.b64"),
              let encoded = try? String(contentsOf: url, encoding: .ascii),
              let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AdbError.executableNotFound("clipboard-helper.dex.b64")
        }
        return data
    }

    public func push(text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AdbError.invalidArgument(String(localized: "Clipboard text must not be empty"))
        }
        let id = UUID().uuidString
        let temp = FileManager.default.temporaryDirectory
        let localHelper = temp.appendingPathComponent("afm-clipboard-\(id).dex")
        let localText = temp.appendingPathComponent("afm-clipboard-\(id).txt")
        let remoteHelper = "/data/local/tmp/adb-file-manager-clipboard-\(id).dex"
        let remoteText = "/data/local/tmp/adb-file-manager-clipboard-\(id).txt"
        defer {
            try? FileManager.default.removeItem(at: localHelper)
            try? FileManager.default.removeItem(at: localText)
        }

        try Self.loadHelper().write(to: localHelper)
        try Data(text.utf8).write(to: localText)
        do {
            try await device.push(localHelper.path, to: remoteHelper)
            try await device.push(localText.path, to: remoteText)
            let user = try await AppPackageService(device: device).currentUser()
            let output = try await device.shell(
                "CLASSPATH=\(remoteHelper) app_process /system/bin \(Self.helperClass) \(remoteText) \(user)", check: true)
            guard output.contains(where: { $0.trimmingCharacters(in: .whitespaces) == Self.successMarker }) else {
                throw AdbError.unexpectedOutput(output.joined(separator: "\n"))
            }
        } catch {
            _ = try? await device.shell("rm -f \(remoteHelper) \(remoteText)")
            throw error
        }
        _ = try? await device.shell("rm -f \(remoteHelper) \(remoteText)")
    }
}
