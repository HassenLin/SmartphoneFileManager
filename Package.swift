// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Smartphone File Manager：Mac ⇄ Android ⇄ iPhone 檔案管理（SwiftUI，源自 AdbFileManager 的 macOS 移植）。
//
// 用 SwiftPM 而不用手寫 .xcodeproj，
// 以檔案系統為準、新增檔案不必改專案檔；缺的 app bundle 外殼由
// `tools/make-app.sh` 補上。Xcode 直接 `open Package.swift` 即可編輯與除錯。
//
// 分層：
//   L0 CLibMTP           — libmtp 的 C 模組（只有標頭，弱連結），MTP 裝置存取用。
//   L1 SFMCore           — 子行程、adb 指令、輸出解析、檔案/App/裝置服務。零 UI 相依，可 swift test。
//   L4 SmartphoneFileManager — SwiftUI app，唯一有 UI 相依的地方。
//
// MTP（libmtp，LGPL）為固定功能：建置必須有 Homebrew 的 libmtp（`brew install libmtp`）。
// 以動態**弱**連結：執行時萬一缺少 libmtp，app 仍可啟動並提示安裝（`MTP.isAvailable == false`），
// 而不是在啟動時就因 dyld 找不到函式庫而閃退。
// Apple Silicon（/opt/homebrew）與 Intel（/usr/local）的 Homebrew 路徑都檢查。
guard let libmtpPrefix = ["/opt/homebrew", "/usr/local"].first(where: {
    FileManager.default.fileExists(atPath: "\($0)/include/libmtp.h")
}) else {
    fatalError("找不到 libmtp（MTP 必要相依）。請先執行：brew install libmtp")
}
// 所有直接或間接 import CLibMTP 的 target 都需要 libmtp.h 的搜尋路徑
let mtpSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(libmtpPrefix)/include"])]
let package = Package(
    name: "SmartphoneFileManager",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SFMCore", targets: ["SFMCore"]),
        .executable(name: "SmartphoneFileManager", targets: ["SmartphoneFileManager"]),
    ],
    targets: [
        .systemLibrary(name: "CLibMTP", path: "Sources/CLibMTP"),
        .target(
            name: "SFMCore",
            dependencies: ["CLibMTP"],
            swiftSettings: mtpSettings,
            linkerSettings: [.unsafeFlags(["-L\(libmtpPrefix)/lib", "-Xlinker", "-weak-lmtp"])]
        ),
        .testTarget(name: "SFMCoreTests", dependencies: ["SFMCore"], swiftSettings: mtpSettings),
        .executableTarget(name: "SmartphoneFileManager", dependencies: ["SFMCore"], swiftSettings: mtpSettings),
    ]
)
