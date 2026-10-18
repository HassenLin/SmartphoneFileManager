import Foundation

/// 傳輸速率與預估剩餘時間（工作列表顯示用）。
///
/// 只累計**實際傳輸**的位元組（進度增量），不含略過／已存在的檔案——否則略過一個大檔案會讓速率暴增。
/// 每滿 `window` 秒取一次樣本，以指數移動平均（新樣本權重 `smoothing`）平滑：
/// 單一檔案的開頭（建立連線、登入）與網路抖動不會讓預估時間大幅跳動。
public struct TransferRate: Sendable, Equatable {
    /// 平滑後的速率（位元組／秒）；樣本不足時為 nil
    public private(set) var bytesPerSecond: Double?
    private var windowStart: Date?
    private var windowBytes: Int64 = 0
    let window: TimeInterval
    let smoothing: Double

    public init(window: TimeInterval = 1, smoothing: Double = 0.3) {
        self.window = window
        self.smoothing = smoothing
    }

    /// 記錄新傳輸的位元組
    public mutating func record(_ bytes: Int64, at now: Date = Date()) {
        guard let start = windowStart else {
            windowStart = now
            windowBytes = max(0, bytes)
            return
        }
        windowBytes += max(0, bytes)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= window else { return }
        let sample = Double(windowBytes) / elapsed
        bytesPerSecond = bytesPerSecond.map { $0 + smoothing * (sample - $0) } ?? sample
        windowStart = now
        windowBytes = 0
    }

    /// 傳完 `remaining` 位元組還要幾秒；速率未知時為 nil
    public func secondsRemaining(_ remaining: Int64) -> TimeInterval? {
        guard let rate = bytesPerSecond, rate > 0 else { return nil }
        return Double(max(0, remaining)) / rate
    }
}

/// 剩餘時間顯示：`0:42`、`12:05`、`1:02:03`
public enum DurationFormat {
    public static func string(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
