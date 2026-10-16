import Foundation
import Testing
@testable import SFMCore

/// 實機整合測試：只在 `SFM_LIVE=1` 時執行（需要一台已授權的 Android 與一台已信任的 iPhone）。
///
///     SFM_LIVE=1 swift test --filter LiveDevice
///
/// 只在各裝置的暫存資料夾 `afm-live-test-<UUID>` 內操作，結束時刪除。
/// 驗證的路徑：Mac→Android、Android→iPhone（經 Mac 中繼）、iPhone 內複製（中繼）、
/// iPhone 內移動（原生 mv）、iPhone→Mac、跨裝置剪下（刪除來源）、資料夾遞迴刪除。
@Suite("LiveDevice", .enabled(if: ProcessInfo.processInfo.environment["SFM_LIVE"] == "1"))
struct LiveDeviceTests {
    @Test func endToEndAcrossMacAndroidAndIPhone() async throws {
        // 優先用系統 adb，沒有就用 repo 內附的 vendor/adb
        let vendored = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../vendor/adb").standardized.path
        let adb = AdbClient(executable: AdbLocator.systemPath() ?? vendored)
        let serial = try #require(try await adb.devices().first(where: \.isReady)?.serial, "需要已授權的 Android 裝置")
        let tool = try #require(IPhoneFileSource.locateTool(), "需要 libimobiledevice")
        let udid = try #require(await IPhoneDeviceInfo.list().first?.udid, "需要已信任的 iPhone")

        let mac = MacFileSource()
        let android = AndroidFileSource(device: adb.device(serial))
        let iphone = IPhoneFileSource(udid: udid, executable: tool)
        let tag = "afm-live-test-\(UUID().uuidString.prefix(8))"
        let androidDir = "/sdcard/Download/\(tag)"
        let iphoneDir = "/Downloads/\(tag)"

        // Mac 測試資料：一個檔案（含中文與空白）+ 一個含子檔的資料夾
        let macDir = FileManager.default.temporaryDirectory.appendingPathComponent(tag)
        try FileManager.default.createDirectory(at: macDir.appendingPathComponent("資料 夾"), withIntermediateDirectories: true)
        try Data("hello 中文".utf8).write(to: macDir.appendingPathComponent("測試 檔.txt"))
        try Data(repeating: 7, count: 300_000).write(to: macDir.appendingPathComponent("資料 夾/blob.bin"))
        defer { try? FileManager.default.removeItem(at: macDir) }

        try await android.makeDirectory(at: androidDir)
        try await iphone.makeDirectory(at: iphoneDir)
        do {
            // 1. Mac → Android
            let macItems = try await mac.list(macDir.path, includeHidden: false)
            var result = try await FileTransfer.run(items: macItems, from: mac, to: android, directory: androidDir, move: false) { _ in }
            #expect(result.failures.isEmpty, "\(result.failures.map(\.message))")
            let onAndroid = try await android.list(androidDir, includeHidden: false)
            #expect(Set(onAndroid.map(\.name)) == ["測試 檔.txt", "資料 夾"])

            // 2. Android → iPhone（經 Mac 中繼，含資料夾）
            result = try await FileTransfer.run(items: onAndroid, from: android, to: iphone, directory: iphoneDir, move: false) { _ in }
            #expect(result.failures.isEmpty, "\(result.failures.map(\.message))")
            let onIPhone = try await iphone.list(iphoneDir, includeHidden: false)
            #expect(Set(onIPhone.map(\.name)) == ["測試 檔.txt", "資料 夾"])
            #expect(try await iphone.list("\(iphoneDir)/資料 夾", includeHidden: false).first?.size == 300_000)

            // 3. iPhone 內複製（同名 → 自動改名，經中繼）
            let file = try #require(onIPhone.first { $0.name == "測試 檔.txt" })
            result = try await FileTransfer.run(items: [file], from: iphone, to: iphone, directory: iphoneDir, move: false) { _ in }
            #expect(result.completed == ["\(iphoneDir)/測試 檔 2.txt"])

            // 4. iPhone 內移動（原生 mv）到子資料夾
            let copy = try #require(try await iphone.list(iphoneDir, includeHidden: false).first { $0.name == "測試 檔 2.txt" })
            result = try await FileTransfer.run(items: [copy], from: iphone, to: iphone, directory: "\(iphoneDir)/資料 夾", move: true) { _ in }
            #expect(result.failures.isEmpty)
            #expect(try await iphone.exists("\(iphoneDir)/資料 夾/測試 檔 2.txt"))

            // 5. iPhone → Mac，內容一致
            let back = macDir.appendingPathComponent("back")
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            result = try await FileTransfer.run(items: [file], from: iphone, to: mac, directory: back.path, move: false) { _ in }
            #expect(try String(contentsOf: back.appendingPathComponent("測試 檔.txt"), encoding: .utf8) == "hello 中文")

            // 6. 跨裝置剪下：iPhone 資料夾 → Android，來源應被刪除
            let folder = try #require(try await iphone.list(iphoneDir, includeHidden: false).first { $0.isDirectory })
            result = try await FileTransfer.run(items: [folder], from: iphone, to: android, directory: androidDir, move: true) { _ in }
            #expect(result.failures.isEmpty, "\(result.failures.map(\.message))")
            #expect(try await !iphone.exists(folder.path))
            #expect(try await android.exists("\(androidDir)/資料 夾 2/測試 檔 2.txt"))
        } catch {
            Issue.record(error)
        }
        // 清理（iPhone 刪除為遞迴實作，本身也是受測項目）
        try await iphone.delete(iphoneDir)
        try await android.delete(androidDir)
        #expect(try await !iphone.exists(iphoneDir))
        #expect(try await !android.exists(androidDir))
    }
}
