import Foundation

/// 單檔傳輸遇到**暫時性錯誤**時等一下再續傳，而不是直接把檔案標為失敗。
///
/// 暫時性錯誤：網路斷線／逾時、連不上伺服器、外接磁碟暫時讀不到（EIO、ENXIO「尚未設定裝置」…）、
/// 或 Mac 端路徑所在的外接磁碟已卸載（拔掉再插回）。帳密錯誤、檔案不存在、目的已存在等不會因為等待而好轉，照常失敗。
///
/// 重試＝重新呼叫一次單檔傳輸，各來源的 `resume*` 從已傳的部分接著做（下載看本機已有大小、
/// pCloud 上傳沿用上傳工作階段、FTP `-c`…），所以不會從頭重傳。
/// 等待期間節點仍為 running、訊息顯示「N 秒後重試」；暫停／停止會立即中斷等待。
public struct TransferRetry: Sendable {
    /// 每次重試前的等待時間；全部用完仍失敗才標為失敗
    public var delays: [Duration]

    public init(delays: [Duration]) { self.delays = delays }

    /// 逐步拉長，合計約 17 分鐘：短暫斷線很快接上，拔插磁碟、換網路也等得到
    public static let standard = TransferRetry(delays: [5, 10, 20, 30, 60, 60, 120, 120, 300, 300].map { .seconds($0) })
    public static let none = TransferRetry(delays: [])

    /// 錯誤本身是否屬於「等一下可能就好」
    public static func isTransient(_ error: Error) -> Bool {
        if let network = error as? NetworkError {
            if case .unreachable = network { return true }
            return false
        }
        if let url = error as? URLError { return transientURLCodes.contains(url.code) }
        return isTransientNSError(error as NSError)
    }

    /// Mac 端路徑所在的外接磁碟是否已卸載（`/Volumes/名稱` 不存在）。此時任何錯誤都視為暫時性
    public static func volumeMissing(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])")
    }

    private static let transientURLCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .secureConnectionFailed, .resourceUnavailable, .internationalRoamingOff,
        .callIsActive, .dataNotAllowed, .cannotLoadFromNetwork,
    ]

    private static let transientPOSIX: Set<Int32> = [
        EIO, ENXIO, ENODEV, ETIMEDOUT, ENETDOWN, ENETUNREACH, ENETRESET, ECONNRESET, ECONNABORTED,
        ECONNREFUSED, EHOSTUNREACH, EHOSTDOWN, EPIPE, ENOTCONN, ESTALE, EAGAIN,
    ]

    /// Foundation 的檔案錯誤多半把 POSIX 錯誤包在 `NSUnderlyingErrorKey` 裡，逐層往下找
    private static func isTransientNSError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain, transientPOSIX.contains(Int32(error.code)) { return true }
        if error.domain == NSURLErrorDomain, transientURLCodes.contains(URLError.Code(rawValue: error.code)) { return true }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isTransientNSError(underlying)
    }
}
