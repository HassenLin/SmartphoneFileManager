import SFMCore
import SwiftUI

/// pCloud 帳號的登入狀態（帳號清單與帳號編輯器共用）。
/// 鑰匙圈有 token 不代表有效（登出、過期、改密碼、舊版登入取得），所以要以 `userinfo` 實際驗證。
enum PCloudTokenStatus: Equatable {
    /// 鑰匙圈沒有 token
    case none
    /// 有 token、驗證中
    case checking
    case valid
    /// 伺服器拒絕 token：需要重新登入
    case expired
    /// 連不上 pCloud，無法確認
    case unverified(String)

    /// 不連網路的初始狀態：有 token 就是「驗證中」
    static func initial(for account: NetworkAccount) -> PCloudTokenStatus {
        CredentialStore.pcloudToken(for: account) == nil ? .none : .checking
    }

    /// 實際驗證。被取消時回傳 nil——取消不是失效，呼叫端不可據此改狀態
    static func check(_ account: NetworkAccount) async -> PCloudTokenStatus? {
        guard let value = CredentialStore.pcloudToken(for: account) else { return PCloudTokenStatus.none }
        do {
            let validity = try await PCloudLogin.validate(PCloudToken(keychainValue: value), region: account.pcloudRegion)
            if Task.isCancelled { return nil }
            switch validity {
            case .valid: return .valid
            case .expired: return .expired
            case let .unknown(reason): return .unverified(reason)
            }
        } catch {
            return nil
        }
    }

    /// 顯示「已登入」區塊（否則顯示 Email／密碼表單）
    var showsAccount: Bool { self != .none && self != .expired }

    /// 帳號清單用的短字
    var shortTitle: String {
        switch self {
        case .none: return String(localized: "Not signed in")
        case .checking: return String(localized: "Checking…")
        case .valid: return String(localized: "Signed in")
        case .expired: return String(localized: "Sign in again")
        case .unverified: return String(localized: "Signed in (unconfirmed)")
        }
    }

    var color: Color {
        switch self {
        case .expired: return .red
        default: return .secondary
        }
    }
}
