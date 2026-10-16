# 背景與設計取捨

原版是 Kotlin + Compose Desktop 的跨平台 app（JVM，約 1.3 萬行）。macOS 版目標是原生 SwiftUI、零 JVM。

| 取捨 | 選擇 | 理由 |
|---|---|---|
| 專案格式 | SwiftPM + `make-app.sh` | 以檔案系統為準，新增檔案不用改 pbxproj；Xcode 可直接開 `Package.swift` |
| 分層 | L1 `AFMCore`（無 UI）＋ L4 App | 解析器、shell 跳脫、子行程取消等最容易錯的部分可單元測試 |
| 狀態管理 | `@Observable` + 協調者 `AppModel` | 取代原版 MVI（Intent/State/Effect）；子模型互不參考，跨窗格動作集中在 AppModel |
| stat 格式 | `%F\|%A\|%s\|%Y\|%n`，檔名放最後並限制切割 | 原版檔名含 `\|` 會錯位 |
| 上傳進度 | 輪詢遠端 `stat -c %s` | 新版 adb 靜默忽略 `push -p` |
| Windows CP936 workaround | 移除 | macOS 無此問題，參數以陣列傳遞 |
| 編碼偵測 | `NSString.stringEncoding(for:)` | 取代 Mozilla UniversalDetector |
| App 名稱/圖示 | **不支援**，只顯示套件名 | 原版用 Java apk-parser；Swift 自寫 AXML/ARSC 解析成本過高 |
| scrcpy | 只偵測並啟動（`brew install scrcpy`） | 原版自動下載；macOS 版 scrcpy 依賴 brew 管理的動態函式庫 |
| 裝置輪詢 | 只跑 `adb devices -l` | 原版每 3 秒對每台裝置跑 `ip route`，改為只在無線連線面板查詢 |
| 終端輸出 | 去除 ANSI 解析 | 無 TTY 的 adb shell 幾乎不輸出色碼 |
| 版本檢查 | 移除 | 自用工具 |
| 書籤 | 沿用 `~/.adbfilemanager/bookmarks.json` | 與 Kotlin 版共用 |
