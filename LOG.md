# LOG

- 2026-10-16｜**初版移植**：自 wkbin/AdbFileManager v3.1.2（Kotlin/Compose）移植為 SwiftUI 原生 app。
  - 架構：SwiftPM + make-app.sh + make-icon.swift。
  - 核心層 AFMCore 29 項測試全過；app 建置零警告；組 .app 後啟動、輪詢、子行程回收已確認。
  - 未完成驗收：已授權實機的檔案操作、UI 截圖（無螢幕錄製權限）、拖到 Finder 的 file promise 行為。
