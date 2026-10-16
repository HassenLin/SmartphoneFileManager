# ADB File Manager — macOS 原生版

[wkbin/AdbFileManager](https://github.com/wkbin/AdbFileManager)（Kotlin + Compose Desktop）的 macOS 移植版，
以 **Swift 6 + SwiftUI** 重寫。結構：SwiftPM 套件 + `tools/make-app.sh` 組 .app。

- **部署目標**：macOS 14+（開發機 macOS 27 / Xcode 27 / Swift 6.4）
- **相依**：零第三方套件；內附 Google platform-tools 的 adb（universal binary）
- **發佈**：自用、ad-hoc 簽章、App Sandbox 關閉（要執行 adb／scrcpy 子行程）
- **語系**：English／繁體中文（跟隨系統）

## 功能

| 區塊 | 說明 |
|---|---|
| 雙窗格 | 左：本機（可收合，狀態記憶）；右：Android 裝置。右鍵「複製到對面」、拖放互傳 |
| 拖放 | 本機/Finder → 裝置（上傳）；裝置 → 本機窗格（下載，有進度可取消）；裝置 → Finder（best-effort，放下時才 pull） |
| 傳輸 | 進度（上傳輪詢遠端大小、下載輪詢本機大小）、可取消（SIGTERM adb 子行程）、取消後清掉新建的不完整檔案 |
| 檔案操作 | 新增資料夾/檔案、改名、權限（chmod 勾選⇄八進位）、裝置內複製/移動、刪除（多選）、遞迴搜尋、書籤、排序、篩選 |
| 編輯器 | NSTextView：語法上色、⌘F 尋找/⌥⌘F 取代、undo、編碼偵測與切換、無損存檔（必要時升級 UTF-8） |
| 終端機 | 獨立視窗多分頁；ADB 模式 ⇄ `adb shell` 模式 FSM、歷史（↑↓）、Tab 補完、拖入檔案插入路徑 |
| 裝置工具 | App 管理（啟動/停止/清資料/停用/備份 APK/解除安裝）、裝置資訊、重開機、截圖、寫入剪貼簿、scrcpy 鏡像、無線配對/連線 |

## 建置 / 執行

```bash
swift test                                          # 核心層單元測試（29 項）
swift tools/make-icon.swift                         # 只在改圖示時需要（產物已 commit）
./tools/make-app.sh && open .build/AdbFileManagerMac.app
./tools/make-app.sh release                         # 釋出版
open Package.swift                                  # 用 Xcode 開發／除錯
```

## 目錄結構

```
Package.swift               SwiftPM（L1 AFMCore + L4 App + 測試）
Sources/AFMCore/            L1：零 UI 相依，可 swift test
  Process/ProcessRunner     子行程唯一入口（可取消、逾時、串流、不經 shell）
  Adb/                      AdbClient/DeviceConnection、AdbLocator（內附/自訂/系統）、ShellText 跳脫、Tokenizer
  Model/                    FileEntry/RemoteFile/LocalFile、StatParser、SortType、TextCodec、Bookmark
  Services/                 RemoteFile／AppPackage／DeviceInfo／Clipboard／Scrcpy
  Terminal/                 AdbShellSession（FSM）、ShellOutputFilter、補完
Sources/AdbFileManagerMac/  L4：SwiftUI app（App/AppModel 為協調者，其餘依功能分資料夾）
Tests/AFMCoreTests/         Swift Testing
Localization/               *.lproj（由 tools/gen-strings.py 自 tools/zh-Hant.json 產生）
vendor/                     adb、clipboard-helper.dex.b64（make-app.sh 放進 Contents/Resources/bin）
tools/                      make-app.sh、make-icon.swift、AppIcon.icns、gen-strings.py、zh-Hant.json
```

## 與原版的差異

見 [`BACKGROUND.md`](BACKGROUND.md)。

## 狀態

- `swift build` 零錯誤零警告；`swift test` 29/29 通過；`.app` 可組出並啟動、裝置輪詢正常、無殭屍行程。
- **待實機驗收**：需一台已授權的 Android 裝置（開發時接的裝置為 unauthorized），以及 UI 截圖驗證（本次 session 無螢幕錄製權限）。

## 更動紀錄

見 [`LOG.md`](LOG.md)。
