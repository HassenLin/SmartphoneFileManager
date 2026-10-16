import CLibMTP
import Darwin
import Foundation

/// MTP 執行時可用性。
public enum MTP {
    /// libmtp 為弱連結：函式庫缺席時符號為 NULL，直接呼叫會當機，所以任何 libmtp 呼叫前都必須先過這一關。
    public static let isAvailable: Bool = {
        // RTLD_DEFAULT = (void *)-2：在已載入的所有映像中找符號
        guard dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LIBMTP_Init") != nil else { return false }
        LIBMTP_Init()
        return true
    }()
}

/// 已開啟的 MTP 裝置（來源選單用）
public struct MTPDeviceInfo: Sendable, Hashable, Identifiable {
    public let serial: String
    public let name: String
    public var id: String { serial }
}
