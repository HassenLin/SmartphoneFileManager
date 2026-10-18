import CryptoKit
import Foundation

/// pCloud 的登入憑證。兩種登入方式拿到的 token 用法不同，所以帶著種類：
/// - `.session`：帳號密碼登入（`userinfo?getauth=1`）取得的 auth token → 每個請求帶 `auth=` 參數。
/// - `.oauth`：OAuth2 access token → `Authorization: Bearer`。
///
/// 鑰匙圈只存一個字串：session token 加 `session:` 前綴，沒有前綴＝OAuth（相容舊版存的 token）。
public struct PCloudToken: Sendable, Equatable {
    public enum Kind: Sendable { case oauth, session }
    public let kind: Kind
    public let value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    private static let sessionPrefix = "session:"

    public init(keychainValue: String) {
        if keychainValue.hasPrefix(Self.sessionPrefix) {
            self.init(kind: .session, value: String(keychainValue.dropFirst(Self.sessionPrefix.count)))
        } else {
            self.init(kind: .oauth, value: keychainValue)
        }
    }

    public var keychainValue: String { kind == .session ? Self.sessionPrefix + value : value }
}

/// 登入結果（帳號密碼或 OAuth 都一樣）：token、帳號實際所在地區、email（有的話）
public struct PCloudSession: Sendable, Equatable {
    public let token: PCloudToken
    public let region: PCloudRegion
    public let email: String?

    public init(token: PCloudToken, region: PCloudRegion, email: String?) {
        self.token = token
        self.region = region
        self.email = email
    }
}

/// pCloud 帳號密碼登入——**不需要**事先註冊 pCloud App（OAuth 需要 client ID／secret 且要等 pCloud 審核）。
///
/// 流程（https://docs.pcloud.com/methods/intro/authentication.html）：
/// 1. `getdigest` 取一次性 digest。
/// 2. `passworddigest = sha1(密碼 + sha1(小寫 email) + digest)`——密碼本身不送出，digest 用過即失效，攔到也無法重放。
/// 3. `login?getauth=1` 換回長效 auth token。帳號啟用兩步驟驗證時回 2297＋暫時 token，
///    須再以 `tfa_login`＋6 位數驗證碼換 auth（`PCloudLogin.verify`）。
///    （官方文件未記載 2FA；作法依 pcloudcom/console-client PR #94 與 seborama/pcloud SDK：
///    要用 `login` 而非 `userinfo`，並帶 `os`／`deviceid`，`trustdevice=1` 讓之後此裝置不必再輸入驗證碼。）
/// 4. 地區：帳號只存在一區，在錯的區登入會失敗 → 先試使用者選的區，失敗再試另一區，成功的那區就是帳號地區。
///
/// 只存 auth token（鑰匙圈），不存密碼；登出時呼叫 `logout` 讓 token 在伺服器端失效。
public enum PCloudLogin {
    /// 帳號啟用兩步驟驗證：UI 向使用者要驗證碼後呼叫 `verify`
    public struct TwoFactorRequired: Error, Sendable, Equatable {
        public let token: String
        public let region: PCloudRegion
        public let email: String
    }

    private struct Response: Decodable {
        let result: Int
        let error: String?
        let digest: String?
        let auth: String?
        let token: String?
        let email: String?
    }

    /// 2297：需要兩步驟驗證；2000：帳密錯誤（在錯的地區登入也回這個）
    static let twoFactorCode = 2297

    public static func signIn(email: String, password: String, preferredRegion: PCloudRegion) async throws -> PCloudSession {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, !password.isEmpty else { throw NetworkError.missingCredential }
        let regions = [preferredRegion] + PCloudRegion.allCases.filter { $0 != preferredRegion }
        var lastError: Error = NetworkError.authenticationFailed("pCloud")
        for region in regions {
            do {
                return try await signIn(email: email, password: password, region: region)
            } catch let error as NetworkError {
                // 帳密錯或帳號不在這區（兩者 pCloud 回同一個錯誤碼）→ 換另一區；其他錯誤（連不上等）直接回報
                guard case .authenticationFailed = error else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private static func signIn(email: String, password: String, region: PCloudRegion) async throws -> PCloudSession {
        let digest = try await call("getdigest", [:], region: region)
        guard let nonce = digest.digest else { throw NetworkError.server("pCloud getdigest: unexpected response") }
        let response = try await call("login", deviceParameters.merging([
            "username": email, "digest": nonce,
            "passworddigest": passwordDigest(email: email, password: password, digest: nonce),
        ]) { $1 }, region: region, allowTwoFactor: true)
        if response.result == twoFactorCode {
            guard let token = response.token else { throw NetworkError.server("pCloud login: two-factor token missing") }
            throw TwoFactorRequired(token: token, region: region, email: email)
        }
        guard let auth = response.auth else { throw NetworkError.server("pCloud userinfo: no auth token") }
        return PCloudSession(token: PCloudToken(kind: .session, value: auth), region: region, email: response.email ?? email)
    }

    /// 兩步驟驗證：以登入時拿到的暫時 token＋驗證碼（App 或簡訊）換 auth token
    public static func verify(_ pending: TwoFactorRequired, code: String) async throws -> PCloudSession {
        let response = try await call("tfa_login", deviceParameters.merging([
            "token": pending.token, "code": code.filter(\.isNumber), "trustdevice": "1",
        ]) { $1 }, region: pending.region)
        guard let auth = response.auth else { throw NetworkError.server("pCloud tfa_login: no auth token") }
        return PCloudSession(token: PCloudToken(kind: .session, value: auth), region: pending.region, email: pending.email)
    }

    /// 登出：讓 auth token 在伺服器端失效（盡力而為；OAuth token 無此 API，只刪鑰匙圈）
    public static func signOut(_ token: PCloudToken, region: PCloudRegion) async {
        guard token.kind == .session else { return }
        _ = try? await call("logout", ["auth": token.value], region: region)
    }

    /// 登入與 2FA 共用：取得 auth、`os`＝6（macOS）、穩定的裝置 id（「信任此裝置」以它辨識）
    private static var deviceParameters: [String: String] {
        ["getauth": "1", "logout": "1", "os": "6", "device": "Smartphone File Manager", "deviceid": deviceID]
    }

    /// 以主機名稱雜湊出固定的裝置 id：同一台 Mac 每次登入都相同，不另存狀態。
    /// 用 `gethostname` 而非 `ProcessInfo.hostName`：後者可能做反向 DNS 查詢而卡住數秒。
    static var deviceID: String {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return String(sha1("Smartphone File Manager/" + host).prefix(32))
    }

    static func passwordDigest(email: String, password: String, digest: String) -> String {
        sha1(password + sha1(email.lowercased()) + digest)
    }

    private static func sha1(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// POST form：帳號與密碼雜湊放本文，不出現在 URL
    private static func call(_ method: String, _ parameters: [String: String], region: PCloudRegion,
                             allowTwoFactor: Bool = false) async throws -> Response {
        var comps = URLComponents()
        comps.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: URL(string: "https://\(region.apiHost)/\(method)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data((comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            throw PCloudClient.map(error)
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw NetworkError.server("pCloud \(method): unexpected response")
        }
        if response.result == 0 || (allowTwoFactor && response.result == twoFactorCode) { return response }
        throw PCloudClient.error(response.result, response.error ?? "", method: method)
    }
}
