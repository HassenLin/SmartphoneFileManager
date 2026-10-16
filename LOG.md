# LOG

- 2026-10-16｜**初版移植**：自 wkbin/AdbFileManager v3.1.2（Kotlin/Compose）移植為 SwiftUI 原生 app。
  - 架構：SwiftPM + make-app.sh + make-icon.swift。
  - 核心層 AFMCore 29 項測試全過；app 建置零警告；組 .app 後啟動、輪詢、子行程回收已確認。
  - 修正：左右窗格未撐滿視窗高度（HSplitView 子視圖需明確 maxHeight: .infinity）。
  - 實機截圖驗證（Palma）：雙窗格列表正常。修正：本機路徑列在根目錄多出 `..`；
    表格欄寬超出窗格產生水平捲軸（名稱欄改為吸收剩餘寬度、其餘欄固定）；
    「下載項目」等受 TCC 保護資料夾讀取失敗時退回個人專屬資料夾，錯誤畫面提供選擇資料夾／打開隱私權設定。
  - 注意：每次 make-app.sh 重新 ad-hoc 簽章，macOS 可能把它當新 App 再次詢問資料夾權限。
  - 未完成驗收：已授權實機的寫入類操作（上傳/下載/編輯/刪除）、終端機、App 管理、拖到 Finder 的 file promise 行為。
