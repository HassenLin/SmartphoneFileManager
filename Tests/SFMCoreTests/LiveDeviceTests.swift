import Foundation
import Testing
@testable import SFMCore

/// 實機整合測試：只在 `SFM_LIVE=1` 時執行（需要一台已授權的 Android 與一台已信任的 iPhone）。
///
///     SFM_LIVE=1 swift test --filter LiveDevice
///
/// 只在各裝置的暫存資料夾 `afm-live-test-<UUID>` 內操作，結束時刪除。
/// 驗證的路徑（經工作佇列）：Mac→Android、Android→iPhone（經 Mac 中繼）、iPhone 內複製（中繼）、
/// iPhone 內移動（原生 mv）、iPhone→Mac、跨裝置剪下（資料夾合併、衝突改名、刪除來源）、資料夾遞迴刪除。
@Suite("LiveDevice", .enabled(if: ProcessInfo.processInfo.environment["SFM_LIVE"] == "1"))
struct LiveDeviceTests {
    /// 以工作佇列執行一個工作並等到結束；衝突一律以 `onConflict` 回答
    @MainActor
    func runJob(_ kind: TransferKind, _ items: [FileItem], from: any FileSource, to: any FileSource,
                directory: String, onConflict: ConflictAction = .rename) async throws -> TransferJob {
        let queue = TransferQueue(store: QueueStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("afm-live-queue-\(UUID().uuidString)")))
        let sources: [SourceID: any FileSource] = [from.id: from, to.id: to]
        queue.resolver = { sources[$0] }
        let id = try #require(queue.enqueue(kind, items: items, from: from.id, to: to.id, directory: directory))
        for _ in 0..<2400 {   // 最多 120 秒
            if let conflict = queue.conflicts.first { queue.answer(conflict.id, action: onConflict, applyToAll: false) }
            if let job = queue.job(id), job.state.isFinished { return job }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AdbError.timedOut(command: "TransferQueue job")
    }

    func failures(_ job: TransferJob) -> [String] {
        job.allNodes.filter { $0.state == .failed }.map { "\($0.name): \($0.message ?? "")" }
    }

    @MainActor
    @Test func endToEndAcrossMacAndroidAndIPhone() async throws {
        // 優先用系統 adb，沒有就用本機放置的 vendor/adb（不收錄於 repo）
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
            var job = try await runJob(.copy, macItems, from: mac, to: android, directory: androidDir)
            #expect(job.state == .completed, "\(failures(job))")
            let onAndroid = try await android.list(androidDir, includeHidden: false)
            #expect(Set(onAndroid.map(\.name)) == ["測試 檔.txt", "資料 夾"])

            // 2. Android → iPhone（經 Mac 中繼，含資料夾）
            job = try await runJob(.copy, onAndroid, from: android, to: iphone, directory: iphoneDir)
            #expect(job.state == .completed, "\(failures(job))")
            let onIPhone = try await iphone.list(iphoneDir, includeHidden: false)
            #expect(Set(onIPhone.map(\.name)) == ["測試 檔.txt", "資料 夾"])
            #expect(try await iphone.list("\(iphoneDir)/資料 夾", includeHidden: false).first?.size == 300_000)

            // 3. iPhone 內複製到同一資料夾（建立副本 → 自動改名，經中繼）
            let file = try #require(onIPhone.first { $0.name == "測試 檔.txt" })
            job = try await runJob(.copy, [file], from: iphone, to: iphone, directory: iphoneDir)
            #expect(job.roots.map(\.targetPath) == ["\(iphoneDir)/測試 檔 2.txt"] && job.state == .completed)

            // 4. iPhone 內移動（原生 mv）到子資料夾
            let copy = try #require(try await iphone.list(iphoneDir, includeHidden: false).first { $0.name == "測試 檔 2.txt" })
            job = try await runJob(.move, [copy], from: iphone, to: iphone, directory: "\(iphoneDir)/資料 夾")
            #expect(job.state == .completed && job.roots.first?.operation == .nativeMove, "\(failures(job))")
            #expect(try await iphone.exists("\(iphoneDir)/資料 夾/測試 檔 2.txt"))

            // 5. iPhone → Mac，內容一致
            let back = macDir.appendingPathComponent("back")
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            job = try await runJob(.copy, [file], from: iphone, to: mac, directory: back.path)
            #expect(try String(contentsOf: back.appendingPathComponent("測試 檔.txt"), encoding: .utf8) == "hello 中文")

            // 6. 跨裝置剪下：iPhone 資料夾 → Android 已有同名資料夾 → 合併；
            //    資料夾內同名檔案（blob.bin）衝突以「重新命名」回答。全部搬完後來源資料夾被刪除
            let folder = try #require(try await iphone.list(iphoneDir, includeHidden: false).first { $0.isDirectory })
            job = try await runJob(.move, [folder], from: iphone, to: android, directory: androidDir)
            #expect(job.state == .completed, "\(failures(job))")
            #expect(try await !iphone.exists(folder.path))
            #expect(try await android.exists("\(androidDir)/資料 夾/測試 檔 2.txt"))
            #expect(try await android.exists("\(androidDir)/資料 夾/blob 2.bin"))
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

    /// Android 續傳：下載（tail -c）、上傳（exec-in cat >>）、裝置內複製（truncate + dd）皆從部分內容接續，結果與原檔一致
    @Test func androidResumableTransfers() async throws {
        let vendored = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../vendor/adb").standardized.path
        let adb = AdbClient(executable: AdbLocator.systemPath() ?? vendored)
        let serial = try #require(try await adb.devices().first(where: \.isReady)?.serial, "需要已授權的 Android 裝置")
        let device = adb.device(serial)
        let android = AndroidFileSource(device: device)
        let tag = "afm-live-test-\(UUID().uuidString.prefix(8))"
        let dir = "/sdcard/Download/\(tag)"
        let macDir = FileManager.default.temporaryDirectory.appendingPathComponent(tag)
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: macDir) }
        let size = 3 << 20
        let content = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) })
        try await android.makeDirectory(at: dir)
        do {
            // 準備：完整檔案上傳到裝置
            let full = macDir.appendingPathComponent("full.bin")
            try content.write(to: full)
            try await android.upload(full, to: "\(dir)/full.bin") { _ in }
            func md5(_ path: String) async throws -> String {
                try await device.shell("md5sum \(ShellText.quote(path))").first?.split(separator: " ").first.map(String.init) ?? ""
            }
            let expected = try await md5("\(dir)/full.bin")

            // 1. 下載續傳：本機先有前 1MB
            let local = macDir.appendingPathComponent("down.bin")
            try content.prefix(1 << 20).write(to: local)
            try await android.resumeDownload("\(dir)/full.bin", to: local, totalSize: Int64(size)) { _ in }
            #expect(try Data(contentsOf: local) == content)

            // 2. 上傳續傳：裝置先有前 1MB
            let head = macDir.appendingPathComponent("head.bin")
            try content.prefix(1 << 20).write(to: head)
            try await android.upload(head, to: "\(dir)/up.bin") { _ in }
            try await android.resumeUpload(full, to: "\(dir)/up.bin") { _ in }
            #expect(try await md5("\(dir)/up.bin") == expected)

            // 3. 裝置內複製續傳：目的先有前 1.5MB（非 1MiB 邊界，驗證截斷對齊）
            _ = try await device.shell("head -c 1572864 \(ShellText.quote("\(dir)/full.bin")) > \(ShellText.quote("\(dir)/cp.bin"))", check: true)
            #expect(try await android.stat("\(dir)/cp.bin")?.size == 1_572_864)
            try await android.resumeCopy("\(dir)/full.bin", to: "\(dir)/cp.bin", totalSize: Int64(size)) { _ in }
            #expect(try await md5("\(dir)/cp.bin") == expected)
        } catch {
            Issue.record(error)
        }
        try await android.delete(dir)
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
