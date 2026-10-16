// swift-tools-version: 6.0
import PackageDescription

// ADB File Manager 的 macOS 原生版（SwiftUI）。
//
// 用 SwiftPM 而不用手寫 .xcodeproj，
// 以檔案系統為準、新增檔案不必改專案檔；缺的 app bundle 外殼由
// `tools/make-app.sh` 補上。Xcode 直接 `open Package.swift` 即可編輯與除錯。
//
// 分層：
//   L1 AFMCore           — 子行程、adb 指令、輸出解析、檔案/App/裝置服務。零 UI 相依，可 swift test。
//   L4 AdbFileManagerMac — SwiftUI app，唯一有 UI 相依的地方。
let package = Package(
    name: "AdbFileManagerMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AFMCore", targets: ["AFMCore"]),
        .executable(name: "AdbFileManagerMac", targets: ["AdbFileManagerMac"]),
    ],
    targets: [
        .target(name: "AFMCore"),
        .testTarget(name: "AFMCoreTests", dependencies: ["AFMCore"]),
        .executableTarget(name: "AdbFileManagerMac", dependencies: ["AFMCore"]),
    ]
)
