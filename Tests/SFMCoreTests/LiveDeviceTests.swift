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
        let iphoneDir = "/\(IPhoneFileSource.mediaFolder)/Downloads/\(tag)"

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
        // App 文件區（house_arrest）：清單可列、虛擬層受保護
        do {
            let apps = try await iphone.list("/Apps", includeHidden: false)
            #expect(!apps.isEmpty, "iPhone 上應有可分享檔案的 App")
            if let first = apps.first {
                _ = try await iphone.list(first.path, includeHidden: true)   // 能列出（可能是空的）
            }
            await #expect(throws: AdbError.self) { try await iphone.delete("/Apps") }
            await #expect(throws: AdbError.self) { try await iphone.makeDirectory(at: "/x") }
        } catch {
            Issue.record(error)
        }

        // 清理（iPhone 刪除為遞迴實作，本身也是受測項目）
        try await iphone.delete(iphoneDir)
        try await android.delete(androidDir)
        #expect(try await !iphone.exists(iphoneDir))
        #expect(try await !android.exists(androidDir))
    }

    /// Android 同裝置 cp，以及內部儲存 → 實體 SD 卡（跨檔案系統的 mv 要整份複製），都必須回報中間進度。
    /// 沒插 SD 卡（`/storage/XXXX-XXXX`）時略過。
    @Test func androidNativeCopyAndMoveReportProgress() async throws {
        let vendored = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../vendor/adb").standardized.path
        let adb = AdbClient(executable: AdbLocator.systemPath() ?? vendored)
        let serial = try #require(try await adb.devices().first(where: \.isReady)?.serial, "需要已授權的 Android 裝置")
        let android = AndroidFileSource(device: adb.device(serial))
        guard let card = try await android.list("/storage", includeHidden: false)
            .first(where: { $0.isDirectory && $0.name.wholeMatch(of: /[0-9A-F]{4}-[0-9A-F]{4}/) != nil }) else { return }

        let tag = "afm-live-test-\(UUID().uuidString.prefix(8))"
        let source = "/sdcard/Download/\(tag).bin"
        let cardDir = "\(card.path)/\(tag)"
        let target = "\(cardDir)/\(tag).bin"
        _ = try await adb.device(serial).shell("dd if=/dev/zero of=\(source) bs=1048576 count=256 2>/dev/null", check: true, timeout: nil)
        try await android.makeDirectory(at: cardDir)

        // 同裝置原生 cp（不經 Mac）也要有中間進度。複製到 SD 卡：內部儲存 256MB 的 cp 不到 0.5 秒，
        // 比第一次輪詢還快，量不到中間值
        let copyTarget = "\(cardDir)/\(tag)-copy.bin"
        let copyReports = Locked<[Double]>([])
        do {
            try await android.copy(source, to: copyTarget) { fraction in copyReports.with { $0.append(fraction) } }
            #expect(try await android.exists(copyTarget))
            let values = copyReports.with { $0 }
            #expect(values.last == 1)
            #expect(values.contains { $0 > 0 && $0 < 1 }, "cp 應有中間進度：\(values)")
        } catch {
            Issue.record(error)
        }
        try? await android.delete(copyTarget)

        let reports = Locked<[Double]>([])
        do {
            try await android.move(source, to: target) { fraction in reports.with { $0.append(fraction) } }
            #expect(try await android.exists(target))
            #expect(try await !android.exists(source))
            let values = reports.with { $0 }
            #expect(values.last == 1)
            #expect(values.contains { $0 > 0 && $0 < 1 }, "跨檔案系統移動應有中間進度：\(values)")
        } catch {
            Issue.record(error)
        }
        try? await android.delete(source)
        try await android.delete(cardDir)
    }
}

/// 進度回呼來自背景 Task，收集時加鎖
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
