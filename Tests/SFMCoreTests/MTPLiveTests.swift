import Foundation
import Testing
@testable import SFMCore

/// MTP 實機測試：只在 `SFM_LIVE=1` 且接著 MTP 裝置時執行。
///
///     SFM_LIVE=1 swift test --filter MTPLive
///
/// 只在第一個儲存空間的 `Download/afm-live-test-<UUID>`（以及第二個儲存空間根目錄的同名資料夾）內操作，結束時刪除。
@Suite("MTPLive", .enabled(if: ProcessInfo.processInfo.environment["SFM_LIVE"] == "1" && MTP.isAvailable))
struct MTPLiveTests {
    @Test func browseTransferAndDeviceSideOperations() async throws {
        let device = try #require(await MTPDeviceManager.shared.refresh().first, "需要已連線的 MTP 裝置")
        let mtp = MTPFileSource(session: try #require(MTPDeviceManager.shared.session(serial: device.serial)))

        let storages = try await mtp.list("/", includeHidden: false)
        print("MTP 儲存空間：\(storages.map(\.path))")
        let first = try #require(storages.first, "裝置需解鎖並開放至少一個儲存空間")
        let tag = "afm-live-test-\(UUID().uuidString.prefix(8))"
        let base = "\(first.path)/Download/\(tag)"

        let macDir = FileManager.default.temporaryDirectory.appendingPathComponent(tag)
        try FileManager.default.createDirectory(at: macDir.appendingPathComponent("資料 夾"), withIntermediateDirectories: true)
        let small = Data("hello 中文".utf8)
        try small.write(to: macDir.appendingPathComponent("測試 檔.txt"))
        try Data(repeating: 7, count: 300_000).write(to: macDir.appendingPathComponent("資料 夾/blob.bin"))
        let big = Data((0..<(32 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try big.write(to: macDir.appendingPathComponent("big.bin"))
        defer { try? FileManager.default.removeItem(at: macDir) }

        try await mtp.makeDirectory(at: base)
        do {
            // 上傳：單檔（有中間進度）、資料夾
            let reports = Locked<[Double]>([])
            try await mtp.upload(macDir.appendingPathComponent("big.bin"), to: "\(base)/big.bin") { f in reports.with { $0.append(f) } }
            #expect(reports.with { $0 }.contains { $0 > 0 && $0 < 1 }, "MTP 上傳應有中間進度")
            try await mtp.upload(macDir.appendingPathComponent("測試 檔.txt"), to: "\(base)/測試 檔.txt") { _ in }
            try await mtp.upload(macDir.appendingPathComponent("資料 夾"), to: "\(base)/資料 夾") { _ in }
            let names = Set(try await mtp.list(base, includeHidden: true).map(\.name))
            #expect(names == ["big.bin", "測試 檔.txt", "資料 夾"])

            // 下載比對（含資料夾）
            let back = macDir.appendingPathComponent("back")
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            try await mtp.download("\(base)/big.bin", to: back.appendingPathComponent("big.bin"), expectedSize: nil) { _ in }
            #expect(try Data(contentsOf: back.appendingPathComponent("big.bin")) == big)
            try await mtp.download("\(base)/資料 夾", to: back.appendingPathComponent("資料 夾"), expectedSize: nil) { _ in }
            #expect(try Data(contentsOf: back.appendingPathComponent("資料 夾/blob.bin")).count == 300_000)

            // 同資料夾改名、同儲存空間移到子資料夾（裝置端 Move Object）
            try await mtp.move("\(base)/測試 檔.txt", to: "\(base)/改名.txt")
            try await mtp.move("\(base)/改名.txt", to: "\(base)/資料 夾/改名.txt")
            #expect(try await mtp.exists("\(base)/資料 夾/改名.txt"))
            #expect(try await !mtp.exists("\(base)/改名.txt"))

            // 裝置端 Copy Object（小檔、同名）與需改名的複製（中繼）
            try await mtp.copy("\(base)/資料 夾/改名.txt", to: "\(base)/改名.txt")
            try await mtp.copy("\(base)/改名.txt", to: "\(base)/改名 2.txt")
            let copied = macDir.appendingPathComponent("copied.txt")
            try await mtp.download("\(base)/改名 2.txt", to: copied, expectedSize: nil) { _ in }
            #expect(try Data(contentsOf: copied) == small)

            // 跨儲存空間移動（有第二個儲存空間時，例如 SD 卡）
            if storages.count > 1 {
                let other = "\(storages[1].path)/\(tag)"
                try await mtp.makeDirectory(at: other)
                try await mtp.move("\(base)/改名 2.txt", to: "\(other)/改名 2.txt")
                #expect(try await mtp.exists("\(other)/改名 2.txt"))
                #expect(try await !mtp.exists("\(base)/改名 2.txt"))
                try await mtp.delete(other)
                #expect(try await !mtp.exists(other))
            }

            // 虛擬層受保護
            await #expect(throws: AdbError.self) { try await mtp.delete(first.path) }
            await #expect(throws: AdbError.self) { try await mtp.makeDirectory(at: "/x") }
        } catch {
            Issue.record(error)
        }
        try await mtp.delete(base)
        #expect(try await !mtp.exists(base))
    }
}
