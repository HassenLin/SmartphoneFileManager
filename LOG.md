# LOG

- 2026-10-16｜**改名 Smartphone File Manager，左右窗格任意來源（Mac／Android／iPhone）＋拷貝／剪下／貼上／刪除**
  - 新增 `FileSource` 抽象（Mac／Android／iPhone）與 `FileTransfer` 傳輸引擎；窗格合併為單一 `BrowserModel`／`BrowserPaneView`。
  - iPhone 走 libimobiledevice `afcclient`（實測行為記錄於 `IPhoneFileSource.swift`）。
  - 修正：`Process.waitUntilExit()` 在測試宿主中卡死 → 改用 `terminationHandler`。
  - 新增 `tools/install.sh`（另一台 Mac 從原始碼安裝）。
  - 測試：38 項單元測試；實機整合測試（Mac→Android→iPhone、iPhone 內複製／移動、跨裝置剪下、遞迴刪除）通過。
  - 首次實機測試因上述卡死中斷，在兩台裝置各留下 `afm-live-test-FB408F3D`（只含測試資料），已手動清除。
  - 模組改名：AFMCore → SFMCore、AdbFileManagerMac → SmartphoneFileManager；Bundle ID 改為 `idv.hassen.smartphonefilemanager.mac`（舊設定不沿用）。

- 2026-10-16｜**初版移植**：自 wkbin/AdbFileManager v3.1.2（Kotlin/Compose）移植為 SwiftUI 原生 app。
  - 架構：SwiftPM + make-app.sh + make-icon.swift。
  - 核心層 SFMCore 29 項測試全過；app 建置零警告；組 .app 後啟動、輪詢、子行程回收已確認。
  - 修正：左右窗格未撐滿視窗高度（HSplitView 子視圖需明確 maxHeight: .infinity）。
  - 實機截圖驗證（Palma）：雙窗格列表正常。修正：本機路徑列在根目錄多出 `..`；
    表格欄寬超出窗格產生水平捲軸（名稱欄改為吸收剩餘寬度、其餘欄固定）；
    「下載項目」等受 TCC 保護資料夾讀取失敗時退回個人專屬資料夾，錯誤畫面提供選擇資料夾／打開隱私權設定。
  - 注意：每次 make-app.sh 重新 ad-hoc 簽章，macOS 可能把它當新 App 再次詢問資料夾權限。
  - 未完成驗收：已授權實機的寫入類操作（上傳/下載/編輯/刪除）、終端機、App 管理、拖到 Finder 的 file promise 行為。
