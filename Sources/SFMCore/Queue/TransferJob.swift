import Foundation

/// 工作種類
public enum TransferKind: String, Codable, Sendable {
    case copy, move, delete
    /// 單向同步（類似 rsync）：只傳新增／變更的檔案，可選刪除目的端多出的項目。見 `SyncPlanner`
    case sync
}

/// 工作的狀態（FSM 停留狀態）。
///
///     pending ──排程──▶ running ⇄ waitingForUser（衝突詢問）
///        ▲  ▲               │
///        │  └──resume── paused ◀──pause──┘
///        │                  │
///        └──────────────────┴──stop──▶ stopped
///     running ──全部完成──▶ completed ／ 有項目失敗 ──▶ failed（可 resume 重試失敗項目）
///
/// 載入保存的佇列時，非終止狀態一律轉為 paused（重開 app 不自動繼續，等使用者按繼續）。
public enum JobState: String, Codable, Sendable {
    /// 排隊中：等待同裝置的其他工作，或等待裝置連線
    case pending
    case running
    /// 等待使用者回答衝突對話框
    case waitingForUser
    case paused
    case completed
    /// 已處理完，但有項目失敗
    case failed
    /// 使用者停止（未完成的項目不再處理，不完整檔案已清除）
    case stopped

    public var isFinished: Bool { self == .completed || self == .failed || self == .stopped }
    /// 佔用裝置通道中
    public var isActive: Bool { self == .running || self == .waitingForUser }
}

/// 樹狀節點的狀態
public enum NodeState: String, Codable, Sendable {
    case pending
    case running
    /// 中斷（暫停／關閉 app）留下部分內容，繼續時直接續傳、不詢問
    case partial
    case done
    case skipped
    case failed
}

/// 節點的實際操作：規劃時決定並保存，繼續時照做
public enum NodeOperation: String, Codable, Sendable {
    /// 同來源內瞬間的改名（同一檔案系統）
    case nativeMove
    /// 在目的建立資料夾（已存在則合併），再處理子項
    case makeDirectory
    /// 單檔傳輸（依來源組合：裝置內續傳複製／下載／上傳／經 Mac 中繼）
    case transferFile
    /// 刪除（刪除工作）
    case delete
    /// 刪除目的端的項目（同步：來源已沒有的項目，或型別不同需先移除的同名項目）
    case deleteTarget
    /// 兩邊都是 Mac 的同步：整個交給 rsync（`sourcePath`／`targetPath` 為兩個資料夾）。可重跑，中斷後繼續＝再跑一次
    case rsync
    /// 規劃時就拒絕（移到自己裡面、已在此資料夾）：不執行，狀態沿用規劃結果
    case rejected
}

/// 工作樹的一個節點（被選取的項目，或展開後的資料夾內容）
public struct TransferNode: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var sourcePath: String
    /// 完整目的路徑（刪除工作為空字串）；衝突選「重新命名」時會改變
    public var targetPath: String
    public var isDirectory: Bool
    public var size: Int64
    public var operation: NodeOperation
    public var state: NodeState
    public var transferred: Int64
    public var message: String?
    /// 移動：此節點完成後刪除來源（檔案傳完即刪；資料夾在子項都完成後刪）
    public var deleteSourceAfter: Bool
    /// nil = 葉節點（OutlineGroup 以此判斷能否展開）
    public var children: [TransferNode]?
    /// 資料夾內容是否已列出。`false`＝尚未展開：執行到這個資料夾時才列出內容（`TransferExecutor.makeDirectory`），
    /// 工作不必等整棵樹掃描完才開始。nil＝已展開（同步規劃、舊佇列檔都是事先展開好的）
    public var expanded: Bool?
    /// 反方向的節點（雙向同步：目的 → 來源）。`sourcePath` 在工作的目的端、`targetPath` 在工作的來源端；
    /// 執行器遇到時以對調來源／目的的執行器處理。nil＝正方向（舊佇列檔沒有這個欄位）
    public var reversed: Bool?

    public init(name: String, sourcePath: String, targetPath: String, isDirectory: Bool, size: Int64,
                operation: NodeOperation, deleteSourceAfter: Bool = false, children: [TransferNode]? = nil,
                state: NodeState = .pending, message: String? = nil) {
        self.id = UUID()
        self.name = name
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.isDirectory = isDirectory
        self.size = size
        self.operation = operation
        self.state = state
        self.transferred = 0
        self.message = message
        self.deleteSourceAfter = deleteSourceAfter
        self.children = children
    }

    /// 本節點與所有子孫的總大小／已完成大小（進度顯示用）
    public var totalBytes: Int64 { (children ?? []).reduce(isDirectory ? 0 : size) { $0 + $1.totalBytes } }
    public var doneBytes: Int64 {
        let own: Int64 = isDirectory ? 0 : (state == .done || state == .skipped ? size : transferred)
        return (children ?? []).reduce(own) { $0 + $1.doneBytes }
    }

    /// 深度優先找節點並修改；找到回傳 true
    @discardableResult
    mutating func update(_ nodeID: UUID, _ body: (inout TransferNode) -> Void) -> Bool {
        if id == nodeID { body(&self); return true }
        guard var list = children else { return false }
        for index in list.indices where list[index].update(nodeID, body) {
            children = list
            return true
        }
        return false
    }

    /// 所有節點（含自己）
    var flattened: [TransferNode] { [self] + (children ?? []).flatMap(\.flattened) }

    /// 尚未列出內容的資料夾（總大小只含已知部分）
    public var isUnexpanded: Bool { expanded == false }
}

/// 衝突處理方式（類似 FTP 客戶端）
public enum ConflictAction: String, Codable, Sendable, CaseIterable {
    /// 從目的檔大小接著傳（目的比來源小、且兩端都支援續傳才提供）
    case resume
    /// 刪除目的檔後整份重傳
    case overwrite
    /// 保留兩者，新檔案改名（`a 2.txt`）
    case rename
    case skip
}

/// 等待使用者決定的衝突
public struct TransferConflict: Sendable, Identifiable {
    public let id = UUID()
    public let jobID: UUID
    public let name: String
    public let sourcePath: String
    public let targetPath: String
    public let source: FileStat
    public let target: FileStat
    /// 是否提供「續傳」
    public let canResume: Bool
}

/// 一個工作（一次拷貝／移動／刪除操作）
public struct TransferJob: Codable, Sendable, Identifiable {
    public let id: UUID
    public var kind: TransferKind
    public var source: SourceID
    public var destination: SourceID?
    public var destinationDirectory: String?
    /// 規劃的輸入（使用者選取的項目）
    public var items: [FileItem]
    /// 規劃後的樹（尚未規劃時為空）
    public var roots: [TransferNode]
    public var planned: Bool
    public var state: JobState
    public var message: String?
    public let createdAt: Date
    /// 「套用到此工作的其餘衝突」選擇的動作
    public var conflictPolicy: ConflictAction?
    /// 同步工作的選項（其他工作為 nil）。`items` 為單一來源資料夾、`destinationDirectory` 為目的資料夾本身
    public var syncOptions: SyncOptions?
    /// 雙向同步（`source`＝左、`destination`＝右）；nil／false 為單向
    public var syncTwoWay: Bool?

    public init(kind: TransferKind, source: SourceID, destination: SourceID?, destinationDirectory: String?, items: [FileItem]) {
        self.id = UUID()
        self.kind = kind
        self.source = source
        self.destination = destination
        self.destinationDirectory = destinationDirectory
        self.items = items
        self.roots = []
        self.planned = false
        self.state = .pending
        self.createdAt = Date()
    }

    /// 佔用的裝置通道：「每台裝置一次一個工作」。只涉及 Mac 的工作用 Mac 自己的通道。
    public var lanes: Set<SourceID> {
        let devices = Set([source, destination].compactMap { $0 }.filter { $0 != .mac })
        return devices.isEmpty ? [.mac] : devices
    }

    public var totalBytes: Int64 { roots.reduce(0) { $0 + $1.totalBytes } }
    public var doneBytes: Int64 { roots.reduce(0) { $0 + $1.doneBytes } }
    /// 已完成比例；尚未規劃或大小未知時以完成的節點數估算
    public var fraction: Double {
        let total = totalBytes
        if total > 0 { return min(1, Double(doneBytes) / Double(total)) }
        let nodes = roots.flatMap(\.flattened)
        guard !nodes.isEmpty else { return 0 }
        return Double(nodes.filter { $0.state == .done || $0.state == .skipped }.count) / Double(nodes.count)
    }

    var allNodes: [TransferNode] { roots.flatMap(\.flattened) }

    /// 還有資料夾尚未展開：`totalBytes` 只是目前已知的部分，之後會再增加
    public var isScanning: Bool { !planned || allNodes.contains { $0.isUnexpanded && $0.state != .done && $0.state != .skipped } }

    /// 正在傳輸的檔案（逐檔時最多一個；網路帳號設定了同時傳輸數時可能多個）
    public var runningFiles: [TransferNode] {
        allNodes.filter { $0.state == .running && $0.operation == .transferFile }
    }

    /// rsync 節點的結果摘要（Mac ↔ Mac 同步；其他工作為 nil）
    public var rsyncSummary: String? {
        let messages = allNodes.filter { $0.operation == .rsync }.compactMap(\.message)
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    /// 同步結果：已傳輸的檔案數、已刪除的項目數（完成提示用）
    public var syncSummary: (copied: Int, deleted: Int) {
        let done = allNodes.filter { $0.state == .done }
        return (done.filter { $0.operation == .transferFile }.count, done.filter { $0.operation == .deleteTarget }.count)
    }

    mutating func updateNode(_ nodeID: UUID, _ body: (inout TransferNode) -> Void) {
        for index in roots.indices where roots[index].update(nodeID, body) { return }
    }
}
