import Foundation

/// iPhone／iPad 的檔案來源，透過 libimobiledevice 的 `afcclient`。
///
/// 硬體／系統背景：macOS 沒有存取 iPhone 檔案的公開 API。iPhone 對電腦開放兩種 AFC 服務：
/// - **媒體區**（`com.apple.afc`）：`/var/mobile/Media`，即 DCIM、Downloads、Books、Recordings…
/// - **App 文件**（`house_arrest`）：每個開啟「檔案分享」（UIFileSharingEnabled）的 App 的
///   Documents 資料夾——也就是 Finder 裡 iPhone「檔案」分頁列出的 App 清單。
///   以 `afcclient --documents <bundle id>` 存取，路徑在 `/Documents` 底下。
///
/// 為了在一個窗格裡同時瀏覽兩者，這裡把它們組成一棵**虛擬樹**：
///
///     /                       （虛擬）
///     ├── Media/…             → 媒體區的 /…
///     └── Apps/               （虛擬）可分享檔案的 App 清單，名稱顯示 App 名稱
///         └── <bundle id>/…   → 該 App 的 /Documents/…
///
/// 虛擬層（`/`、`/Apps`、`/Apps/<id>` 本身）不可改名、刪除，也不能直接上傳到 `/`、`/Apps`。
/// 不同服務之間（媒體區 ⇄ App、App A ⇄ App B）沒有原生 mv，會經 Mac 暫存區中繼。
///
/// afcclient 的實測行為（libimobiledevice 1.4.0、iOS 27）：
/// - **錯誤時結束碼仍為 0**，只能從輸出的 `Error: ...` 判斷失敗。
/// - `rm` 不支援遞迴，非空資料夾回 "Directory not empty"，因此由這裡自行逐層刪除。
/// - 沒有 copy；複製一律交給 `FileTransfer` 經 Mac 暫存區中繼（`nativeCopy = false`）。
/// - `ls -l` 等指令的旗標必須放在 `--` 之後，否則被 afcclient 自己的選項解析器吃掉。
/// - `get -rf DIR LOCALDIR/` 會在 LOCALDIR 底下建立同名資料夾；`put -rf DIR TARGET` 則直接建立 TARGET。
/// - 互動模式（stdin 管線）讀到 EOF 不會結束，所以每個操作都起一個獨立行程。
/// - `--documents` 時 AFC 根目錄本身無權限（Permission denied），只能操作 `/Documents` 以下。
public struct IPhoneFileSource: FileSource {
    public let udid: String
    public let executable: String

    public init(udid: String, executable: String) {
        self.udid = udid
        self.executable = executable
    }

    public var id: SourceID { .iphone(udid) }
    public var homePath: String { "/" }
    public var capabilities: SourceCapabilities { SourceCapabilities(nativeCopy: false) }

    public static let mediaFolder = "Media"
    public static let appsFolder = "Apps"

    /// 找 afcclient（Homebrew 預設位置）；未安裝時為 nil
    public static func locateTool(_ name: String = "afcclient") -> String? {
        AdbLocator.findExecutable(name)
    }

    // MARK: 虛擬路徑

    /// 虛擬路徑解析後的實際位置
    enum Location: Equatable {
        case root
        case appsRoot
        /// 媒體區內的 AFC 路徑
        case media(String)
        /// App 文件區：bundle id 與 house_arrest 內的 AFC 路徑（`/Documents…`）
        case app(String, String)
        /// 不屬於 Media／Apps 的路徑（例如 `/x`）——不存在，任何操作都拒絕
        case invalid

        /// 可以在裡面放東西／列內容的實體位置（非虛擬層）
        var isReal: Bool {
            switch self {
            case .media, .app: return true
            default: return false
            }
        }

        /// 是否為虛擬層或服務根（不可改名、刪除）
        var isProtected: Bool {
            switch self {
            case .root, .appsRoot, .invalid: return true
            case let .media(path): return path == "/"
            case let .app(_, path): return path == "/Documents"
            }
        }

        /// 同一 AFC 服務才能原生 mv
        func sameService(as other: Location) -> Bool {
            switch (self, other) {
            case (.media, .media): return true
            case let (.app(a, _), .app(b, _)): return a == b
            default: return false
            }
        }
    }

    static func resolve(_ virtualPath: String) -> Location {
        let parts = RemotePath.components(virtualPath)
        guard let first = parts.first else { return .root }
        switch first {
        case mediaFolder:
            return .media("/" + parts.dropFirst().joined(separator: "/"))
        case appsFolder:
            guard parts.count >= 2 else { return .appsRoot }
            let rest = parts.dropFirst(2).joined(separator: "/")
            return .app(parts[1], rest.isEmpty ? "/Documents" : "/Documents/" + rest)
        default:
            // 不可退回「當作媒體區」：那會讓 `/x` 之類的路徑在媒體區根目錄真的建立／刪除東西
            return .invalid
        }
    }

    /// 由 AFC 實際路徑換回虛擬路徑
    static func virtualPath(for location: Location) -> String {
        switch location {
        case .root, .invalid: return "/"
        case .appsRoot: return "/\(appsFolder)"
        case let .media(path): return RemotePath.join("/\(mediaFolder)", String(path.dropFirst()))
        case let .app(bundle, path):
            let rest = path.hasPrefix("/Documents") ? String(path.dropFirst("/Documents".count)) : path
            return RemotePath.normalize("/\(appsFolder)/\(bundle)/\(rest)")
        }
    }

    // MARK: afcclient

    /// 執行一個 afcclient 指令；輸出含 `Error:` 即視為失敗
    @discardableResult
    func run(_ arguments: [String], bundle: String? = nil, timeout: Duration? = .seconds(30)) async throws -> [String] {
        var args = ["-u", udid]
        if let bundle { args += ["--documents", bundle] }
        let output = try await ProcessRunner.run(executable, args + ["--"] + arguments, timeout: timeout)
        let lines = output.lines
        if let error = lines.first(where: { $0.hasPrefix("Error:") || $0.hasPrefix("ERROR:") || $0.hasPrefix("No device found")
            || $0.hasPrefix("The App ") }) {
            throw AdbError.commandFailed(exitCode: output.exitCode, output: error)
        }
        if output.exitCode != 0 {
            throw AdbError.commandFailed(exitCode: output.exitCode, output: output.text)
        }
        return lines
    }

    /// 在某位置執行指令：自動帶入 `--documents` 與實際路徑
    private func run(_ command: String, _ location: Location, _ extra: [String] = [], flags: [String] = [],
                     timeout: Duration? = .seconds(30)) async throws -> [String] {
        switch location {
        case let .media(path): return try await run([command] + flags + [path] + extra, timeout: timeout)
        case let .app(bundle, path): return try await run([command] + flags + [path] + extra, bundle: bundle, timeout: timeout)
        default: throw Self.virtualFolderError
        }
    }

    static var virtualFolderError: AdbError {
        .invalidArgument(String(localized: "This is a virtual folder. Open Media or an app folder first."))
    }

    // MARK: 瀏覽

    public func list(_ directory: String, includeHidden: Bool) async throws -> [FileItem] {
        let location = Self.resolve(directory)
        switch location {
        case .root:
            return [
                FileItem(path: "/\(Self.mediaFolder)", name: Self.mediaFolder, isDirectory: true, permissions: "dr-xr-xr-x"),
                FileItem(path: "/\(Self.appsFolder)", name: Self.appsFolder, isDirectory: true, permissions: "dr-xr-xr-x"),
            ]
        case .appsRoot:
            return try await IPhoneAppCatalog.shared.apps(udid: udid).map { app in
                FileItem(path: "/\(Self.appsFolder)/\(app.bundleID)", name: app.name, isDirectory: true, permissions: "dr-xr-xr-x")
            }
        case .invalid:
            throw AdbError.cannotOpenDirectory(directory)
        case .media, .app:
            let lines: [String]
            do {
                lines = try await run("ls", location, flags: ["-l"])
            } catch AdbError.commandFailed {
                throw AdbError.cannotOpenDirectory(directory)
            }
            return Self.parseLongListing(lines, parent: RemotePath.normalize(directory))
                .filter { includeHidden || !$0.isHidden }
        }
    }

    /// 解析 `ls -l`：`drwxr-xr-x    2 mobile mobile    64 20 Sep 2025 00:31:29 名稱（可含空白）`
    /// 時間為 Mac 本地時區（afcclient 以 localtime 格式化）。
    static func parseLongListing(_ lines: [String], parent: String) -> [FileItem] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss"
        let regex = /^([dlbcps-][rwxsStT-]{9})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2}) (.+)$/
        return lines.compactMap { line in
            guard let match = line.firstMatch(of: regex) else { return nil }
            let permissions = String(match.1)
            let name = String(match.4)
            guard name != ".", name != ".." else { return nil }
            return FileItem(path: RemotePath.join(parent, name), name: name,
                            isDirectory: permissions.hasPrefix("d"),
                            size: Int64(match.2) ?? 0,
                            modified: formatter.date(from: String(match.3)),
                            permissions: permissions)
        }
    }

    /// `info` 回傳 JSON（st_ifmt 等）；不存在時丟錯
    private func info(_ location: Location) async throws -> [String: Any] {
        let text = try await run("info", location).joined(separator: "\n")
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdbError.unexpectedOutput(text)
        }
        return object
    }

    public func isDirectory(_ path: String) async throws -> Bool {
        let location = Self.resolve(path)
        if location == .invalid { return false }
        guard location.isReal else { return true }
        if case let .app(_, afcPath) = location, afcPath == "/Documents" { return true }
        guard let info = try? await info(location) else { return false }
        return info["st_ifmt"] as? String == "S_IFDIR"
    }

    public func exists(_ path: String) async throws -> Bool {
        let location = Self.resolve(path)
        if location == .invalid { return false }
        guard location.isReal else { return true }
        return (try? await info(location)) != nil
    }

    // MARK: 修改

    public func makeDirectory(at path: String) async throws {
        let location = Self.resolve(path)
        guard location.isReal, !location.isProtected else { throw Self.virtualFolderError }
        try await run("mkdir", location)
    }

    public func move(_ path: String, to target: String) async throws {
        let from = Self.resolve(path), to = Self.resolve(target)
        guard from.isReal, to.isReal, !from.isProtected else { throw Self.virtualFolderError }
        if from.sameService(as: to) {
            switch (from, to) {
            case let (.media(a), .media(b)): try await run(["mv", a, b])
            case let (.app(bundle, a), .app(_, b)): try await run(["mv", a, b], bundle: bundle)
            default: break
            }
            return
        }
        // 不同服務之間沒有 mv：經 Mac 暫存區複製後刪除原件
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("afm-mv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let local = staging.appendingPathComponent(RemotePath.name(of: path))
        try await download(path, to: local, expectedSize: nil) { _ in }
        try await upload(local, to: target) { _ in }
        try await delete(path)
    }

    public func copy(_ path: String, to target: String) async throws {
        throw AdbError.invalidArgument("AFC has no copy; FileTransfer stages through the Mac")
    }

    /// AFC 的 rm 不遞迴：資料夾先刪內容（含隱藏檔）再刪自己
    public func delete(_ path: String) async throws {
        let location = Self.resolve(path)
        guard location.isReal, !location.isProtected else { throw Self.virtualFolderError }
        if try await isDirectory(path) {
            for child in try await list(path, includeHidden: true) {
                try Task.checkCancellation()
                try await delete(child.path)
            }
        }
        try await run("rm", location)
    }

    // MARK: 傳輸

    /// iPhone → Mac。資料夾：`get -rf` 會在目的資料夾下建立同名資料夾，
    /// 所以先抓到暫存父目錄，再搬到指定的完整路徑（可能是改過名的）。
    public func download(_ path: String, to localURL: URL, expectedSize: Int64?,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let location = Self.resolve(path)
        guard location.isReal else { throw Self.virtualFolderError }
        if try await isDirectory(path) {
            let staging = localURL.deletingLastPathComponent()
                .appendingPathComponent(".afm-get-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try await run("get", location, [staging.path + "/"], flags: ["-rf"], timeout: nil)
            let afcPath: String
            switch location {
            case let .media(p), let .app(_, p): afcPath = p
            default: afcPath = path
            }
            try FileManager.default.moveItem(at: staging.appendingPathComponent(RemotePath.name(of: afcPath)), to: localURL)
        } else {
            try await withLocalSizePolling(localURL, expectedSize: expectedSize, onProgress: onProgress) {
                try await run("get", location, [localURL.path], flags: ["-f"], timeout: nil)
            }
        }
        onProgress(1)
    }

    public func upload(_ localURL: URL, to path: String, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            throw AdbError.invalidArgument(String(localized: "Local file does not exist: \(localURL.path)"))
        }
        let location = Self.resolve(path)
        guard location.isReal, !location.isProtected else { throw Self.virtualFolderError }
        // put 的參數順序是 LOCAL REMOTE，與其他指令「路徑在前」不同，直接組參數
        let remote: String
        let bundle: String?
        switch location {
        case let .media(p): (remote, bundle) = (p, nil)
        case let .app(b, p): (remote, bundle) = (p, b)
        default: throw Self.virtualFolderError
        }
        try await run(["put", isDirectory.boolValue ? "-rf" : "-f", localURL.path, remote], bundle: bundle, timeout: nil)
        onProgress(1)
    }

    /// 下載單檔時輪詢本機檔案大小回報進度
    private func withLocalSizePolling(_ localURL: URL, expectedSize: Int64?,
                                      onProgress: @escaping @Sendable (Double) -> Void,
                                      _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            if let expectedSize, expectedSize > 0 {
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(150))
                        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
                        onProgress(min(1, Double(size) / Double(expectedSize)))
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

/// 可分享檔案的 App（Finder「檔案」分頁的清單）
public struct IPhoneApp: Sendable, Hashable {
    public let bundleID: String
    public let name: String
}

/// App 清單快取：`ideviceinstaller list` 列出 600+ 個 App 要數秒，每台裝置快取 2 分鐘。
public actor IPhoneAppCatalog {
    public static let shared = IPhoneAppCatalog()
    private var cache: [String: (date: Date, apps: [IPhoneApp])] = [:]

    public func apps(udid: String, refresh: Bool = false) async throws -> [IPhoneApp] {
        if !refresh, let entry = cache[udid], Date().timeIntervalSince(entry.date) < 120 { return entry.apps }
        guard let tool = AdbLocator.findExecutable("ideviceinstaller") else {
            throw AdbError.executableNotFound(String(localized: "ideviceinstaller (brew install ideviceinstaller) — needed to list iPhone apps"))
        }
        let output = try await ProcessRunner.run(tool, [
            "-u", udid, "list", "--all", "--xml",
            "-a", "CFBundleIdentifier", "-a", "CFBundleDisplayName", "-a", "CFBundleName", "-a", "UIFileSharingEnabled",
        ], timeout: .seconds(60))
        let apps = try Self.parse(output.data)
        cache[udid] = (Date(), apps)
        return apps
    }

    /// 解析 `ideviceinstaller list --xml`，只留 UIFileSharingEnabled 的 App，依名稱排序
    static func parse(_ data: Data) throws -> [IPhoneApp] {
        guard let start = data.range(of: Data("<?xml".utf8))?.lowerBound else {
            throw AdbError.unexpectedOutput(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let plist = try PropertyListSerialization.propertyList(from: data[start...], format: nil)
        guard let entries = plist as? [[String: Any]] else { throw AdbError.unexpectedOutput("not an array") }
        return entries.compactMap { entry -> IPhoneApp? in
            guard entry["UIFileSharingEnabled"] as? Bool == true,
                  let bundle = entry["CFBundleIdentifier"] as? String, !bundle.isEmpty else { return nil }
            let name = (entry["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (entry["CFBundleName"] as? String) ?? bundle
            return IPhoneApp(bundleID: bundle, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// 已連接的 iPhone（`idevice_id -l` + `ideviceinfo -k DeviceName`）
public struct IPhoneDeviceInfo: Identifiable, Hashable, Sendable {
    public let udid: String
    public let name: String
    public var id: String { udid }

    public init(udid: String, name: String) {
        self.udid = udid
        self.name = name
    }

    /// 列出 USB 連接的 iPhone；libimobiledevice 未安裝時回傳空陣列
    public static func list(knownNames: [String: String] = [:]) async -> [IPhoneDeviceInfo] {
        guard let idevice = AdbLocator.findExecutable("idevice_id") else { return [] }
        guard let output = try? await ProcessRunner.run(idevice, ["-l"], timeout: .seconds(10)) else { return [] }
        let udids = output.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var result: [IPhoneDeviceInfo] = []
        for udid in udids {
            if let name = knownNames[udid] {
                result.append(IPhoneDeviceInfo(udid: udid, name: name))
                continue
            }
            var name = "iPhone"
            if let info = AdbLocator.findExecutable("ideviceinfo"),
               let out = try? await ProcessRunner.run(info, ["-u", udid, "-k", "DeviceName"], timeout: .seconds(10)),
               out.exitCode == 0, let first = out.lines.first, !first.isEmpty, !first.hasPrefix("ERROR") {
                name = first
            }
            result.append(IPhoneDeviceInfo(udid: udid, name: name))
        }
        return result
    }
}
