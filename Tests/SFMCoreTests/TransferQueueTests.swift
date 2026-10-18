import Foundation
import Testing
@testable import SFMCore

/// 工作佇列：規劃、逐檔執行、衝突處理、暫停／繼續（含重開 app）、停止。
/// 以 FakeSource 模擬裝置；每個測試用獨立的暫存佇列資料夾。
@MainActor
@Suite("TransferQueue", .serialized)
struct TransferQueueTests {
    let storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("afm-queue-test-\(UUID().uuidString)")

    func makeDevice(_ id: SourceID, nativeCopy: Bool = true, delay: Duration = .zero) -> (FakeSource, FakeStore) {
        let store = FakeStore()
        store.files["/a/x.txt"] = Data("x".utf8)
        store.files["/a/dir/y.txt"] = Data("y".utf8)
        store.directories.formUnion(["/a", "/a/dir", "/b"])
        return (FakeSource(id: id, store: store, nativeCopy: nativeCopy, delay: delay), store)
    }

    func makeQueue(_ sources: [any FileSource]) -> TransferQueue {
        let map = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let queue = TransferQueue(store: QueueStore(directory: storeDirectory))
        queue.resolver = { map[$0] }
        return queue
    }

    func items(_ source: FakeSource, _ paths: [String]) async throws -> [FileItem] {
        try await source.list("/a", includeHidden: true).filter { paths.contains($0.path) }
    }

    /// 等到條件成立（最多 3 秒）
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等待逾時")
    }

    func finished(_ queue: TransferQueue, _ id: UUID?) async throws -> TransferJob {
        let id = try #require(id)
        try await wait { queue.job(id)?.state.isFinished == true }
        return try #require(queue.job(id))
    }

    // MARK: 同步（rsync）

    @Test func syncCopiesOnlyChangesAndDeletesExtraneous() async throws {
        let (android, _) = makeDevice(.android("A"))
        let (iphone, phone) = makeDevice(.iphone("U"), nativeCopy: false)
        phone.files["/b/x.txt"] = Data("x".utf8)            // 相同 → 不動
        phone.files["/b/dir/y.txt"] = Data("old".utf8)      // 大小不同 → 覆寫（不詢問）
        phone.files["/b/old.txt"] = Data("o".utf8)          // 來源沒有 → 刪除
        phone.files["/b/.keep"] = Data("k".utf8)            // 隱藏且不含隱藏檔 → 不碰
        phone.directories.insert("/b/dir")
        let queue = makeQueue([android, iphone])
        let job = try await finished(queue, queue.enqueueSync(
            from: FolderLocation(source: android.id, path: "/a"), to: FolderLocation(source: iphone.id, path: "/b"),
            options: SyncOptions(deleteExtraneous: true, includeHidden: false)))
        #expect(job.state == .completed && queue.conflicts.isEmpty)
        #expect(phone.files["/b/dir/y.txt"] == Data("y".utf8))
        #expect(phone.files["/b/old.txt"] == nil)
        #expect(phone.files["/b/.keep"] != nil)
        let operations = job.allNodes.map(\.operation)
        #expect(operations.filter { $0 == .transferFile }.count == 1)
        #expect(operations.filter { $0 == .deleteTarget }.count == 1)

        // 再同步一次：已一致，只剩根節點
        let again = try await finished(queue, queue.enqueueSync(
            from: FolderLocation(source: android.id, path: "/a"), to: FolderLocation(source: iphone.id, path: "/b"),
            options: SyncOptions(deleteExtraneous: true, includeHidden: false)))
        #expect(again.state == .completed && again.allNodes.count == 1)
    }

    @Test func syncIntoMissingFolderCreatesItAndRejectsOverlap() async throws {
        let (android, store) = makeDevice(.android("A"))
        let queue = makeQueue([android])
        let job = try await finished(queue, queue.enqueueSync(
            from: FolderLocation(source: android.id, path: "/a"), to: FolderLocation(source: android.id, path: "/c"),
            options: SyncOptions()))
        #expect(job.state == .completed)
        #expect(store.files["/c/dir/y.txt"] == Data("y".utf8))
        let overlap = try await finished(queue, queue.enqueueSync(
            from: FolderLocation(source: android.id, path: "/a"), to: FolderLocation(source: android.id, path: "/a/dir"),
            options: SyncOptions()))
        #expect(overlap.state == .failed)
    }

    @Test func twoWaySyncNewerWinsAndDoesNotCopyBack() async throws {
        let (android, left) = makeDevice(.android("A"))
        let (iphone, right) = makeDevice(.iphone("U"), nativeCopy: false)
        let old = Date(timeIntervalSinceNow: -3600), new = Date(timeIntervalSinceNow: -60)
        left.files = ["/a/same.txt": Data("s".utf8), "/a/l-newer.txt": Data("L2".utf8), "/a/r-newer.txt": Data("r".utf8),
                      "/a/only-left.txt": Data("ol".utf8)]
        left.modified = ["/a/same.txt": old, "/a/l-newer.txt": new, "/a/r-newer.txt": old, "/a/only-left.txt": old]
        right.files = ["/b/same.txt": Data("s".utf8), "/b/l-newer.txt": Data("l".utf8), "/b/r-newer.txt": Data("R2".utf8),
                       "/b/sub/only-right.txt": Data("or".utf8)]
        right.modified = ["/b/same.txt": old, "/b/l-newer.txt": old, "/b/r-newer.txt": new, "/b/sub/only-right.txt": old]
        right.directories.insert("/b/sub")
        let queue = makeQueue([android, iphone])
        let sync = { queue.enqueueSync(from: FolderLocation(source: android.id, path: "/a"),
                                       to: FolderLocation(source: iphone.id, path: "/b"),
                                       options: SyncOptions(deleteExtraneous: true), twoWay: true) }
        let job = try await finished(queue, sync())
        #expect(job.state == .completed)
        #expect(right.files["/b/l-newer.txt"] == Data("L2".utf8))
        #expect(left.files["/a/r-newer.txt"] == Data("R2".utf8))
        #expect(right.files["/b/only-left.txt"] == Data("ol".utf8))
        #expect(left.files["/a/sub/only-right.txt"] == Data("or".utf8))
        #expect(job.syncSummary.copied == 4 && job.syncSummary.deleted == 0)
    }

    @Test func twoWayUndecidableIsSkipped() async throws {
        let (android, left) = makeDevice(.android("A"))
        let (iphone, right) = makeDevice(.iphone("U"), nativeCopy: false)
        left.files["/a/x.txt"] = Data("xx".utf8)          // 大小不同、兩邊都沒有時間 → 分不出新舊
        right.files["/b/x.txt"] = Data("x".utf8)
        let queue = makeQueue([android, iphone])
        let job = try await finished(queue, queue.enqueueSync(
            from: FolderLocation(source: android.id, path: "/a"), to: FolderLocation(source: iphone.id, path: "/b"),
            options: SyncOptions(), twoWay: true))
        #expect(left.files["/a/x.txt"] == Data("xx".utf8) && right.files["/b/x.txt"] == Data("x".utf8))
        #expect(job.allNodes.contains { $0.operation == .rejected && $0.state == .skipped })
    }

    // MARK: 規劃與執行

    @Test func sameSourceInstantMoveIsNative() async throws {
        let (android, store) = makeDevice(.android("A"))
        let queue = makeQueue([android])
        let job = try await finished(queue, queue.enqueue(.move, items: try await items(android, ["/a/x.txt"]),
                                                          from: android.id, to: android.id, directory: "/b"))
        #expect(job.state == .completed)
        #expect(job.roots.map(\.operation) == [.nativeMove])
        #expect(store.log == ["mv /a/x.txt /b/x.txt"])
    }

    @Test func sameFolderCopyMakesDuplicateLikeFinder() async throws {
        let (android, store) = makeDevice(.android("A"))
        let queue = makeQueue([android])
        let job = try await finished(queue, queue.enqueue(.copy, items: try await items(android, ["/a/x.txt"]),
                                                          from: android.id, to: android.id, directory: "/a"))
        #expect(job.state == .completed && queue.conflicts.isEmpty)
        #expect(store.files["/a/x 2.txt"] == Data("x".utf8))
    }

    @Test func moveIntoSameFolderIsSkippedAndIntoItselfFails() async throws {
        let (android, store) = makeDevice(.android("A"))
        let queue = makeQueue([android])
        let skipped = try await finished(queue, queue.enqueue(.move, items: try await items(android, ["/a/x.txt"]),
                                                              from: android.id, to: android.id, directory: "/a"))
        #expect(skipped.roots.first?.state == .skipped && store.log.isEmpty)
        let failed = try await finished(queue, queue.enqueue(.move, items: try await items(android, ["/a/dir"]),
                                                             from: android.id, to: android.id, directory: "/a/dir"))
        #expect(failed.state == .failed)
    }

    @Test func crossDeviceCopyExpandsFolderAndStagesThroughMac() async throws {
        let (android, _) = makeDevice(.android("A"))
        let (iphone, iphoneStore) = makeDevice(.iphone("U"), nativeCopy: false)
        let queue = makeQueue([android, iphone])
        let job = try await finished(queue, queue.enqueue(.copy, items: try await items(android, ["/a/dir"]),
                                                          from: android.id, to: iphone.id, directory: "/b"))
        #expect(job.state == .completed)
        #expect(job.roots.first?.operation == .makeDirectory)
        #expect(job.roots.first?.children?.map(\.name) == ["y.txt"])
        #expect(iphoneStore.files["/b/dir/y.txt"] == Data("y".utf8))
        #expect(!FileManager.default.fileExists(atPath: QueueStore(directory: storeDirectory).staging(for: job.id).path))
    }

    @Test func parallelTransfersRespectLimitAcrossNestedFolders() async throws {
        let store = FakeStore()
        store.directories.formUnion(["/a", "/a/dir", "/a/dir/sub", "/b"])
        for index in 0..<5 { store.files["/a/dir/f\(index).txt"] = Data("\(index)".utf8) }
        for index in 0..<4 { store.files["/a/dir/sub/g\(index).txt"] = Data("\(index)".utf8) }
        var cloud = FakeSource(id: .network(UUID()), store: store, nativeCopy: false, delay: .milliseconds(40))
        cloud.parallel = 3
        var other = FakeSource(id: .network(UUID()), store: FakeStore(), nativeCopy: false)
        other.parallel = 3
        other.store.directories.insert("/b")
        let queue = makeQueue([cloud, other])
        let job = try await finished(queue, queue.enqueue(.move, items: [FileItem(path: "/a/dir", isDirectory: true, size: 0)],
                                                          from: cloud.id, to: other.id, directory: "/b"))
        #expect(job.state == .completed)
        #expect(other.store.files.count == 9 && other.store.files["/b/dir/sub/g3.txt"] == Data("3".utf8))
        // 巢狀資料夾共用名額：確實並行，但從不超過 3
        #expect(store.maxActiveDownloads > 1 && store.maxActiveDownloads <= 3)
        // 移動：全部傳完才刪來源資料夾
        #expect(store.files.isEmpty && !store.directories.contains("/a/dir"))
    }

    @Test func pauseDuringParallelTransfersThenResume() async throws {
        let store = FakeStore()
        store.directories.formUnion(["/a", "/a/dir", "/a/dir/sub"])
        for index in 0..<6 { store.files["/a/dir/f\(index).txt"] = Data("\(index)".utf8) }
        for index in 0..<3 { store.files["/a/dir/sub/g\(index).txt"] = Data("\(index)".utf8) }
        var cloud = FakeSource(id: .network(UUID()), store: store, nativeCopy: false, delay: .milliseconds(120))
        cloud.parallel = 3
        var other = FakeSource(id: .network(UUID()), store: FakeStore(), nativeCopy: false)
        other.parallel = 3
        other.store.directories.insert("/b")
        let queue = makeQueue([cloud, other])
        let id = try #require(queue.enqueue(.copy, items: [FileItem(path: "/a/dir", isDirectory: true, size: 0)],
                                            from: cloud.id, to: other.id, directory: "/b"))
        // 有檔案正在並行傳輸時暫停：所有進行中的檔案轉 partial，沒有節點停在 running
        try await wait { (queue.job(id)?.runningFiles.count ?? 0) > 1 }
        queue.pause(id)
        try await wait { queue.job(id)?.state == .paused }
        let paused = try #require(queue.job(id))
        #expect(!paused.allNodes.contains { $0.state == .running })
        #expect(paused.allNodes.contains { $0.state == .partial })
        queue.resume(id)
        let job = try await finished(queue, id)
        #expect(job.state == .completed && other.store.files.count == 9)
        #expect(store.maxActiveDownloads <= 3)
    }

    @Test func queueSplitsBySizeIntoMainAndSubExecutors() async throws {
        let store = FakeStore()
        store.directories.formUnion(["/a", "/a/dir"])
        for index in 0..<3 { store.files["/a/dir/big\(index).bin"] = Data(repeating: 1, count: 100) }   // ≥ 門檻 → 主執行器
        for index in 0..<6 { store.files["/a/dir/s\(index).txt"] = Data("\(index)".utf8) }               // 小檔 → 子執行器
        var cloud = FakeSource(id: .network(UUID()), store: store, nativeCopy: false, delay: .milliseconds(40))
        cloud.parallel = 3
        cloud.threshold = 50
        var other = FakeSource(id: .network(UUID()), store: FakeStore(), nativeCopy: false)
        other.parallel = 3
        other.store.directories.insert("/b")
        let queue = makeQueue([cloud, other])
        let job = try await finished(queue, queue.enqueue(.copy, items: [FileItem(path: "/a/dir", isDirectory: true, size: 0)],
                                                          from: cloud.id, to: other.id, directory: "/b"))
        #expect(job.state == .completed && other.store.files.count == 9)
        // 大檔進主執行器（多連線）、小檔進子執行器（單一連線）；主執行器一次只處理一個大檔
        #expect(store.connections["/a/dir/big0.bin"] == 4 && store.connections["/a/dir/s0.txt"] == 1)
        #expect(store.maxActiveLarge == 1)
        // 主 1 ＋ 子 2：總同時數不超過同時傳輸數
        #expect(store.maxActiveDownloads <= 3 && store.maxActiveDownloads > 1)
    }

    @Test func currentFileTracksMainExecutorOnly() async throws {
        let store = FakeStore()
        store.directories.formUnion(["/a", "/a/dir"])
        store.files["/a/dir/big.bin"] = Data(repeating: 1, count: 100)
        for index in 0..<6 { store.files["/a/dir/s\(index).txt"] = Data("\(index)".utf8) }
        var cloud = FakeSource(id: .network(UUID()), store: store, nativeCopy: false, delay: .milliseconds(80))
        cloud.parallel = 3
        cloud.threshold = 50
        var other = FakeSource(id: .network(UUID()), store: FakeStore(), nativeCopy: false)
        other.parallel = 3
        other.store.directories.insert("/b")
        let queue = makeQueue([cloud, other])
        let id = try #require(queue.enqueue(.copy, items: [FileItem(path: "/a/dir", isDirectory: true, size: 0)],
                                            from: cloud.id, to: other.id, directory: "/b"))
        // 主執行器開始後，「目前」指向大檔；子執行器的小檔同時在傳也不會取代它
        try await wait { queue.mainFiles[id] != nil }
        let job = try #require(queue.job(id))
        #expect(job.runningFile(queue.mainFiles[id])?.name == "big.bin")
        _ = try await finished(queue, id)
        #expect(queue.mainFiles[id] == nil && queue.mainRates[id] == nil)
    }

    @Test func singleLaneIsMainExecutor() async throws {
        let store = FakeStore()
        store.directories.formUnion(["/a", "/a/dir"])
        store.files["/a/dir/big.bin"] = Data(repeating: 1, count: 100)
        store.files["/a/dir/s.txt"] = Data("s".utf8)
        var cloud = FakeSource(id: .network(UUID()), store: store, nativeCopy: false)
        cloud.threshold = 50
        let mac = MacFileSource()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("sfm-lane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        let queue = makeQueue([cloud, mac])
        let job = try await finished(queue, queue.enqueue(.copy, items: [FileItem(path: "/a/dir", isDirectory: true, size: 0)],
                                                          from: cloud.id, to: mac.id, directory: target.path))
        // 同時傳輸數 1：逐檔，唯一的執行器即主執行器——主執行器一律多連線，不論大小
        #expect(job.state == .completed && store.maxActiveDownloads == 1)
        #expect(store.connections["/a/dir/big.bin"] == 4 && store.connections["/a/dir/s.txt"] == 4)
    }

    @Test func phoneSideKeepsTransfersSequential() async throws {
        let (android, store) = makeDevice(.android("A"), delay: .milliseconds(20))
        store.files["/a/dir/z.txt"] = Data("z".utf8)
        var cloud = FakeSource(id: .network(UUID()), store: FakeStore(), nativeCopy: false)
        cloud.parallel = 4
        cloud.store.directories.insert("/b")
        let queue = makeQueue([android, cloud])
        let job = try await finished(queue, queue.enqueue(.copy, items: [FileItem(path: "/a/dir", isDirectory: true, size: 0)],
                                                          from: android.id, to: cloud.id, directory: "/b"))
        #expect(job.state == .completed && store.maxActiveDownloads == 1)
    }

    @Test func crossDeviceMoveDeletesSourcesAfterCopy() async throws {
        let (android, androidStore) = makeDevice(.android("A"))
        let (iphone, iphoneStore) = makeDevice(.iphone("U"), nativeCopy: false)
        let queue = makeQueue([android, iphone])
        let job = try await finished(queue, queue.enqueue(.move, items: try await items(android, ["/a/x.txt", "/a/dir"]),
                                                          from: android.id, to: iphone.id, directory: "/b"))
        #expect(job.state == .completed)
        #expect(iphoneStore.files["/b/x.txt"] == Data("x".utf8) && iphoneStore.files["/b/dir/y.txt"] == Data("y".utf8))
        #expect(androidStore.files["/a/x.txt"] == nil && androidStore.files["/a/dir/y.txt"] == nil)
        #expect(!androidStore.directories.contains("/a/dir"))
    }

    @Test func deviceToMacAndBack() async throws {
        let (android, store) = makeDevice(.android("A"))
        let mac = MacFileSource()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afm-xfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = makeQueue([android, mac])

        let down = try await finished(queue, queue.enqueue(.copy, items: try await items(android, ["/a/dir"]),
                                                           from: android.id, to: .mac, directory: root.path))
        #expect(down.state == .completed)
        #expect(try String(contentsOf: root.appendingPathComponent("dir/y.txt"), encoding: .utf8) == "y")

        // 上傳回裝置：/b 沒有同名項目，不會有衝突
        let up = try await finished(queue, queue.enqueue(.copy, items: try await mac.list(root.path, includeHidden: false),
                                                         from: .mac, to: android.id, directory: "/b"))
        #expect(up.state == .completed)
        #expect(store.files["/b/dir/y.txt"] == Data("y".utf8))
    }

    @Test func deleteJob() async throws {
        let (android, store) = makeDevice(.android("A"))
        let queue = makeQueue([android])
        let job = try await finished(queue, queue.enqueue(.delete, items: try await items(android, ["/a/dir"]), from: android.id))
        #expect(job.state == .completed && store.files["/a/dir/y.txt"] == nil)
    }

    // MARK: 衝突

    func conflictSetup() async throws -> (TransferQueue, FakeStore, [FileItem], SourceID, SourceID) {
        let (android, _) = makeDevice(.android("A"))
        let (other, otherStore) = makeDevice(.android("B"))
        otherStore.files["/b/x.txt"] = Data("old".utf8)
        let queue = makeQueue([android, other])
        return (queue, otherStore, try await items(android, ["/a/x.txt"]), android.id, other.id)
    }

    @Test func conflictRenameKeepsBoth() async throws {
        let (queue, store, picked, from, to) = try await conflictSetup()
        let id = queue.enqueue(.copy, items: picked, from: from, to: to, directory: "/b")
        try await wait { !queue.conflicts.isEmpty }
        let conflict = try #require(queue.conflicts.first)
        #expect(conflict.target.size == 3 && conflict.source.size == 1 && !conflict.canResume)  // 目的比來源大，不可續傳
        #expect(queue.job(try #require(id))?.state == .waitingForUser)
        queue.answer(conflict.id, action: .rename, applyToAll: false)
        let job = try await finished(queue, id)
        #expect(job.state == .completed)
        #expect(store.files["/b/x.txt"] == Data("old".utf8) && store.files["/b/x 2.txt"] == Data("x".utf8))
        #expect(job.roots.first?.name == "x 2.txt")
    }

    @Test func conflictOverwriteAndSkip() async throws {
        let (queue, store, picked, from, to) = try await conflictSetup()
        let skip = queue.enqueue(.copy, items: picked, from: from, to: to, directory: "/b")
        try await wait { !queue.conflicts.isEmpty }
        queue.answer(queue.conflicts[0].id, action: .skip, applyToAll: false)
        #expect(try await finished(queue, skip).roots.first?.state == .skipped)
        #expect(store.files["/b/x.txt"] == Data("old".utf8))

        let overwrite = queue.enqueue(.copy, items: picked, from: from, to: to, directory: "/b")
        try await wait { !queue.conflicts.isEmpty }
        queue.answer(queue.conflicts[0].id, action: .overwrite, applyToAll: false)
        #expect(try await finished(queue, overwrite).state == .completed)
        #expect(store.files["/b/x.txt"] == Data("x".utf8))
    }

    @Test func conflictApplyToAllAsksOnce() async throws {
        let (android, androidStore) = makeDevice(.android("A"))
        androidStore.files["/a/z.txt"] = Data("z".utf8)
        let (other, otherStore) = makeDevice(.android("B"))
        otherStore.files["/b/x.txt"] = Data("old".utf8)
        otherStore.files["/b/z.txt"] = Data("old".utf8)
        let queue = makeQueue([android, other])
        let id = queue.enqueue(.copy, items: try await items(android, ["/a/x.txt", "/a/z.txt"]),
                               from: android.id, to: other.id, directory: "/b")
        try await wait { !queue.conflicts.isEmpty }
        queue.answer(queue.conflicts[0].id, action: .overwrite, applyToAll: true)
        let job = try await finished(queue, id)
        #expect(job.state == .completed && job.conflictPolicy == .overwrite)
        #expect(otherStore.files["/b/x.txt"] == Data("x".utf8) && otherStore.files["/b/z.txt"] == Data("z".utf8))
    }

    // MARK: 暫停／繼續／停止

    @Test func pausePersistsAcrossRelaunchAndResumes() async throws {
        let (android, androidStore) = makeDevice(.android("A"))
        for name in ["p", "q", "r"] { androidStore.files["/a/\(name).bin"] = Data(name.utf8) }
        let (slow, slowStore) = makeDevice(.android("B"), delay: .milliseconds(150))
        let queue = makeQueue([android, slow])
        let id = try #require(queue.enqueue(.copy, items: try await items(android, ["/a/p.bin", "/a/q.bin", "/a/r.bin"]),
                                            from: android.id, to: slow.id, directory: "/b"))
        // 第一個檔案完成後暫停
        try await wait { queue.job(id)?.allNodes.contains { $0.state == .done } == true }
        queue.pause(id)
        try await wait { queue.job(id)?.state == .paused }

        // 暫停後沒有節點停留在 running（資料夾不會一直顯示轉圈）
        #expect(!(queue.job(id)?.allNodes.contains { $0.state == .running } ?? true))

        // 「重開 app」：從同一個保存位置建立新佇列，工作仍是暫停、已完成的節點保留
        let relaunched = makeQueue([android, slow])
        let restored = try #require(relaunched.job(id))
        #expect(restored.state == .paused && restored.planned)
        #expect(restored.allNodes.contains { $0.state == .done })
        #expect(!restored.allNodes.contains { $0.state == .running })

        relaunched.resume(id)
        let job = try await finished(relaunched, id)
        #expect(job.state == .completed)
        #expect(slowStore.files["/b/p.bin"] != nil && slowStore.files["/b/q.bin"] != nil && slowStore.files["/b/r.bin"] != nil)
    }

    @Test func stopMarksStoppedAndKeepsCompletedFiles() async throws {
        let (android, androidStore) = makeDevice(.android("A"))
        for name in ["p", "q", "r"] { androidStore.files["/a/\(name).bin"] = Data(name.utf8) }
        let (slow, slowStore) = makeDevice(.android("B"), delay: .milliseconds(150))
        let queue = makeQueue([android, slow])
        let id = try #require(queue.enqueue(.copy, items: try await items(android, ["/a/p.bin", "/a/q.bin", "/a/r.bin"]),
                                            from: android.id, to: slow.id, directory: "/b"))
        try await wait { queue.job(id)?.allNodes.contains { $0.state == .done } == true }
        queue.stop(id)
        try await wait { queue.job(id)?.state == .stopped }
        // 已完成的保留；傳到一半的（partial）被清除；未開始的不存在（列表順序不固定，依節點狀態檢查）
        for node in try #require(queue.job(id)).allNodes {
            #expect((slowStore.files[node.targetPath] != nil) == (node.state == .done), "\(node.name) \(node.state)")
        }
        queue.remove(id)
        #expect(queue.job(id) == nil)
    }

    @Test func oneJobPerDeviceAtATime() async throws {
        let (android, androidStore) = makeDevice(.android("A"))
        androidStore.files["/a/z.txt"] = Data("z".utf8)
        let (slow, _) = makeDevice(.android("B"), delay: .milliseconds(150))
        let queue = makeQueue([android, slow])
        let first = try #require(queue.enqueue(.copy, items: try await items(android, ["/a/x.txt"]),
                                               from: android.id, to: slow.id, directory: "/b"))
        let second = try #require(queue.enqueue(.copy, items: try await items(android, ["/a/z.txt"]),
                                                from: android.id, to: slow.id, directory: "/b"))
        #expect(queue.job(first)?.state == .running)
        #expect(queue.job(second)?.state == .pending)
        _ = try await finished(queue, second)
        #expect(queue.job(first)?.state == .completed)
    }
}

/// 資料夾延後展開與速率／剩餘時間（不必等整棵樹掃描完才開始）
@Suite("TransferProgress")
struct TransferProgressTests {
    @Test func plannerDoesNotListFolders() async throws {
        let store = FakeStore()
        store.files["/a/dir/sub/z.txt"] = Data("z".utf8)
        store.directories.formUnion(["/a", "/a/dir", "/a/dir/sub", "/b"])
        let source = FakeSource(id: .android("A"), store: store)
        let destination = FakeSource(id: .iphone("U"), store: FakeStore(), nativeCopy: false)
        let job = TransferJob(kind: .copy, source: source.id, destination: destination.id, destinationDirectory: "/b",
                              items: [FileItem(path: "/a/dir", isDirectory: true, size: 0)])
        let roots = try await TransferPlanner.plan(job, source: source, destination: destination)
        // 規劃只建立節點：資料夾內容等執行到時才列出
        #expect(roots.first?.isUnexpanded == true && roots.first?.children == [])
        // 展開一層：子資料夾同樣先不展開
        let children = try await TransferPlanner.children(of: try #require(roots.first), from: source)
        #expect(children.map(\.name) == ["sub"] && children.first?.isUnexpanded == true)
        #expect(children.first?.targetPath == "/b/dir/sub")
    }

    @Test func rateSmoothsSamplesAndEstimates() {
        let start = Date(timeIntervalSince1970: 0)
        var rate = TransferRate(window: 1, smoothing: 0.5)
        rate.record(0, at: start)
        #expect(rate.bytesPerSecond == nil && rate.secondsRemaining(100) == nil)
        rate.record(1000, at: start.addingTimeInterval(1))       // 第一個樣本 1000 B/s
        #expect(rate.bytesPerSecond == 1000)
        rate.record(3000, at: start.addingTimeInterval(2))       // 3000 B/s → 平滑後 2000
        #expect(rate.bytesPerSecond == 2000)
        rate.record(500, at: start.addingTimeInterval(2.5))      // 未滿一個視窗，不更新
        #expect(rate.bytesPerSecond == 2000)
        #expect(rate.secondsRemaining(10_000) == 5)
        rate.record(-50, at: start.addingTimeInterval(3))         // 負增量視為 0；此視窗共 500 B → 500 B/s，平滑後 1250
        #expect(rate.bytesPerSecond == 1250)
    }

    @Test func durationFormat() {
        #expect(DurationFormat.string(41.2) == "0:42")
        #expect(DurationFormat.string(725) == "12:05")
        #expect(DurationFormat.string(3723) == "1:02:03")
    }
}
