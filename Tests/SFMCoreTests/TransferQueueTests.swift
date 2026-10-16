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
