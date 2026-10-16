import Foundation

/// 同步工作的規劃（類似 `rsync -r` 的快速比對）：比對兩邊資料夾，只產生需要做的節點。
///
/// 規則（遞迴、每層各列一次兩邊目錄）：
/// - 來源有、目的沒有：資料夾 `.makeDirectory`（子項全部傳）、檔案 `.transferFile`。
/// - 兩邊都是檔案：**大小不同**，或**來源修改時間比目的新**（容許 2 秒誤差，FAT／MTP 時間精度只到 2 秒）才傳。
///   各來源無法保留修改時間（傳過去的檔案時間＝傳輸當下），所以不能用 rsync 的「時間不相等」，
///   改用「來源較新」；兩邊任一方沒有時間時只比大小。
/// - 兩邊都是資料夾：遞迴；子項都不用動時整個資料夾不產生節點。
/// - 同名但型別不同（檔案 ↔ 資料夾）：先 `.deleteTarget` 再建立／傳輸。
/// - `deleteExtraneous`：目的有、來源沒有的項目 `.deleteTarget`（排在同層最前面，先騰出空間）。
/// - `includeHidden == false`、`excludePatterns`：兩邊符合的項目都不碰（不傳也不刪）。
/// - `sizeOnly`：只比大小；`ignoreExisting`：目的已有的檔案不動。
/// - 兩邊都是這台 Mac：不自己比對，產生 `.rsync` 節點交給 rsync（見 `RsyncCommand`）；雙向為兩個節點
///   （左 → 右、右 → 左，皆 `--update`；rsync -a 保留時間，第二趟不會把剛傳過去的檔案再傳回來）。
///
/// 雙向（`twoWay`，見 `twoWayDiff`）：**先一次比對完兩邊再執行**。裝置無法保留修改時間，
/// 若拆成兩個單向工作，第一趟傳過去的檔案時間變成「現在」，第二趟會誤判為較新而整批傳回。
///
/// 回傳以目的資料夾本身為根的 `.makeDirectory` 節點（已存在則合併），子項為比對結果；
/// 兩邊已一致時根節點沒有子項，工作立即完成。
enum SyncPlanner {
    static let timeTolerance: TimeInterval = 2

    static func plan(from sourceDirectory: String, to targetDirectory: String, source: any FileSource,
                     destination: any FileSource, options: SyncOptions, twoWay: Bool = false) async throws -> [TransferNode] {
        let from = RemotePath.normalize(sourceDirectory)
        let to = RemotePath.normalize(targetDirectory)
        if source.id == destination.id, to == from || to.hasPrefix(from + "/") || from.hasPrefix(to + "/") {
            return [TransferNode(name: RemotePath.name(of: to), sourcePath: from, targetPath: to, isDirectory: true, size: 0,
                                 operation: .rejected, state: .failed,
                                 message: String(localized: "The two folders overlap; cannot sync a folder with itself"))]
        }
        if SyncCapabilities(from: source.id, to: destination.id).usesRsync {
            let forward = TransferNode(name: RemotePath.name(of: to), sourcePath: from, targetPath: to, isDirectory: false,
                                       size: 0, operation: .rsync)
            guard twoWay else { return [forward] }
            var backward = TransferNode(name: RemotePath.name(of: from), sourcePath: to, targetPath: from, isDirectory: false,
                                        size: 0, operation: .rsync)
            backward.reversed = true
            return [forward, backward]
        }
        let targetExists = try await destination.stat(to)?.isDirectory == true
        let children = twoWay
            ? try await twoWayDiff(from, to, rightExists: targetExists, left: source, right: destination, options: options)
            : try await diff(from, to, targetExists: targetExists, source: source, destination: destination, options: options)
        return [TransferNode(name: RemotePath.name(of: to), sourcePath: from, targetPath: to, isDirectory: true, size: 0,
                             operation: .makeDirectory, children: children)]
    }

    /// 雙向比對（以左 → 右為正方向，右 → 左的節點標 `reversed`）：
    /// - 只在一邊：整個拷到另一邊（資料夾沿用單向 `diff` 展開）。
    /// - 兩邊都是檔案：修改時間較新的一方覆蓋另一方（容許 2 秒）；時間相近且大小相同＝一致。
    ///   大小不同卻分不出新舊（沒有時間，或時間相近）：不動，標為略過並說明，交給使用者處理。
    /// - 兩邊都是資料夾：遞迴。同名但一邊檔案一邊資料夾：不動，標為略過。
    /// - 不刪除任何項目（`deleteExtraneous` 不適用）；`ignoreExisting`：兩邊都有的檔案不動；
    ///   `sizeOnly`：大小相同即視為一致。
    static func twoWayDiff(_ leftDirectory: String, _ rightDirectory: String, rightExists: Bool,
                           left: any FileSource, right: any FileSource, options: SyncOptions) async throws -> [TransferNode] {
        try Task.checkCancellation()
        let visible: (FileItem) -> Bool = { !options.excludes($0.name) }
        let leftItems = try await left.list(leftDirectory, includeHidden: options.includeHidden).filter(visible)
        let rightItems = rightExists ? try await right.list(rightDirectory, includeHidden: options.includeHidden).filter(visible) : []
        let leftByName = Dictionary(leftItems.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let rightByName = Dictionary(rightItems.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var oneWay = options
        oneWay.deleteExtraneous = false

        var nodes: [TransferNode] = []
        for name in Set(leftByName.keys).union(rightByName.keys).sorted() {
            let leftPath = RemotePath.join(leftDirectory, name)
            let rightPath = RemotePath.join(rightDirectory, name)
            switch (leftByName[name], rightByName[name]) {
            case let (l?, nil):
                nodes.append(try await copyNode(l, to: rightPath, from: left, into: right, options: oneWay))
            case let (nil, r?):
                nodes.append(reversed(try await copyNode(r, to: leftPath, from: right, into: left, options: oneWay)))
            case let (l?, r?) where l.isDirectory && r.isDirectory:
                let children = try await twoWayDiff(leftPath, rightPath, rightExists: true, left: left, right: right, options: options)
                if !children.isEmpty {
                    nodes.append(TransferNode(name: name, sourcePath: leftPath, targetPath: rightPath, isDirectory: true,
                                              size: 0, operation: .makeDirectory, children: children))
                }
            case let (l?, r?) where !l.isDirectory && !r.isDirectory:
                if options.ignoreExisting { continue }
                switch newer(l, r, sizeOnly: options.sizeOnly) {
                case .same: continue
                case .left:
                    nodes.append(TransferNode(name: name, sourcePath: leftPath, targetPath: rightPath, isDirectory: false,
                                              size: l.size, operation: .transferFile))
                case .right:
                    nodes.append(reversed(TransferNode(name: name, sourcePath: rightPath, targetPath: leftPath,
                                                       isDirectory: false, size: r.size, operation: .transferFile)))
                case .unknown:
                    nodes.append(TransferNode(name: name, sourcePath: leftPath, targetPath: rightPath, isDirectory: false,
                                              size: l.size, operation: .rejected, state: .skipped,
                                              message: String(localized: "Both sides changed; cannot tell which is newer")))
                }
            default:
                nodes.append(TransferNode(name: name, sourcePath: leftPath, targetPath: rightPath, isDirectory: false,
                                          size: 0, operation: .rejected, state: .skipped,
                                          message: String(localized: "A file and a folder have the same name")))
            }
        }
        return nodes
    }

    enum Newer: Equatable { case same, left, right, unknown }

    /// 雙向比對兩個檔案哪邊較新
    static func newer(_ left: FileItem, _ right: FileItem, sizeOnly: Bool) -> Newer {
        let sameSize = left.size == right.size
        if sameSize && sizeOnly { return .same }
        guard let leftDate = left.modified, let rightDate = right.modified else { return sameSize ? .same : .unknown }
        let delta = leftDate.timeIntervalSince(rightDate)
        if delta > timeTolerance { return .left }
        if delta < -timeTolerance { return .right }
        return sameSize ? .same : .unknown
    }

    /// 只在一邊的項目：檔案一個節點、資料夾整個展開
    private static func copyNode(_ item: FileItem, to target: String, from source: any FileSource,
                                 into destination: any FileSource, options: SyncOptions) async throws -> TransferNode {
        guard item.isDirectory else {
            return TransferNode(name: item.name, sourcePath: item.path, targetPath: target, isDirectory: false,
                                size: item.size, operation: .transferFile)
        }
        let children = try await diff(item.path, target, targetExists: false, source: source, destination: destination, options: options)
        return TransferNode(name: item.name, sourcePath: item.path, targetPath: target, isDirectory: true,
                            size: 0, operation: .makeDirectory, children: children)
    }

    /// 整棵子樹標為反方向
    private static func reversed(_ node: TransferNode) -> TransferNode {
        var copy = node
        copy.reversed = true
        copy.children = node.children?.map(reversed)
        return copy
    }

    static func diff(_ sourceDirectory: String, _ targetDirectory: String, targetExists: Bool,
                     source: any FileSource, destination: any FileSource, options: SyncOptions) async throws -> [TransferNode] {
        try Task.checkCancellation()
        let visible: (FileItem) -> Bool = { !options.excludes($0.name) }
        let sourceItems = try await source.list(sourceDirectory, includeHidden: options.includeHidden)
            .filter(visible).sorted { $0.name < $1.name }
        let targetItems = targetExists
            ? try await destination.list(targetDirectory, includeHidden: true).filter(visible) : []
        let targetByName = Dictionary(targetItems.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let sourceNames = Set(sourceItems.map(\.name))

        var nodes: [TransferNode] = []
        if options.deleteExtraneous {
            for item in targetItems.sorted(by: { $0.name < $1.name }) where !sourceNames.contains(item.name) {
                nodes.append(deleteNode(item))
            }
        }
        for item in sourceItems {
            let target = RemotePath.join(targetDirectory, item.name)
            let existing = targetByName[item.name]
            if let existing, existing.isDirectory != item.isDirectory {
                nodes.append(deleteNode(existing))
            }
            let sameType = existing.map { $0.isDirectory == item.isDirectory } ?? false
            if item.isDirectory {
                let children = try await diff(item.path, target, targetExists: sameType,
                                              source: source, destination: destination, options: options)
                if sameType && children.isEmpty { continue }
                nodes.append(TransferNode(name: item.name, sourcePath: item.path, targetPath: target, isDirectory: true,
                                          size: 0, operation: .makeDirectory, children: children))
            } else {
                if sameType, let existing, options.ignoreExisting || !needsUpdate(item, existing, sizeOnly: options.sizeOnly) {
                    continue
                }
                nodes.append(TransferNode(name: item.name, sourcePath: item.path, targetPath: target, isDirectory: false,
                                          size: item.size, operation: .transferFile))
            }
        }
        return nodes
    }

    static func needsUpdate(_ source: FileItem, _ target: FileItem, sizeOnly: Bool = false) -> Bool {
        if source.size != target.size { return true }
        if sizeOnly { return false }
        guard let sourceDate = source.modified, let targetDate = target.modified else { return false }
        return sourceDate.timeIntervalSince(targetDate) > timeTolerance
    }

    private static func deleteNode(_ item: FileItem) -> TransferNode {
        TransferNode(name: item.name, sourcePath: "", targetPath: item.path, isDirectory: item.isDirectory,
                     size: 0, operation: .deleteTarget)
    }
}
