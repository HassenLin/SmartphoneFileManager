// swift-tools-version: 6.0
import PackageDescription

// Smartphone File Manager：Mac ⇄ Android ⇄ iPhone 檔案管理（SwiftUI，源自 AdbFileManager 的 macOS 移植）。
//
// 用 SwiftPM 而不用手寫 .xcodeproj，
// 以檔案系統為準、新增檔案不必改專案檔；缺的 app bundle 外殼由
// `tools/make-app.sh` 補上。Xcode 直接 `open Package.swift` 即可編輯與除錯。
//
// 分層：
//   L1 SFMCore           — 子行程、adb 指令、輸出解析、檔案/App/裝置服務。零 UI 相依，可 swift test。
//   L4 SmartphoneFileManager — SwiftUI app，唯一有 UI 相依的地方。
let package = Package(
    name: "SmartphoneFileManager",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SFMCore", targets: ["SFMCore"]),
        .executable(name: "SmartphoneFileManager", targets: ["SmartphoneFileManager"]),
    ],
    targets: [
        .target(name: "SFMCore"),
        .testTarget(name: "SFMCoreTests", dependencies: ["SFMCore"]),
        .executableTarget(name: "SmartphoneFileManager", dependencies: ["SFMCore"]),
    ]
)
