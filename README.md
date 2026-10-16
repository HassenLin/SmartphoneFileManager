# Smartphone File Manager（macOS）

在 Mac 上同時管理 **Mac、Android、iPhone** 檔案的雙窗格檔案管理器，以 **Swift 6 + SwiftUI** 撰寫。
源自 [wkbin/AdbFileManager](https://github.com/wkbin/AdbFileManager)（Kotlin/Compose）的 macOS 移植，
並擴充為任意來源 ⇄ 任意來源。結構：SwiftPM 套件 + `tools/make-app.sh`。

- **部署目標**：macOS 14+（開發機 macOS 27 / Xcode 27 / Swift 6.4）
- **Android**：內附 adb（亦可改用 Android SDK／Homebrew 的 adb）
- **iPhone**：透過 libimobiledevice（`brew install libimobiledevice ideviceinstaller`）。根目錄分兩個虛擬資料夾：
  `Media`（DCIM、Downloads、Books…）與 `Apps`（開啟檔案分享的 App 及其 Documents，等同 Finder 的「檔案」分頁）
- **發佈**：自用、ad-hoc 簽章、App Sandbox 關閉；**語系**：English／繁體中文／简体中文（跟隨系統語言）
- **安裝導引**：缺 adb、libimobiledevice、scrcpy 時於 app 內顯示步驟、官方下載連結與一鍵安裝指令（輔助說明 → 安裝導引）

## 功能

| 區塊 | 說明 |
|---|---|
| 雙窗格、任意來源 | **左右窗格各自**以標題的來源按鈕選擇：這台 Mac、任一 Android、任一 iPhone；同一台裝置可在兩邊同時開不同資料夾。選擇會記住 |
| 拷貝／剪下／貼上 | 表格焦點時 ⌘C／⌘X／⌘V；右鍵「拷貝、剪下、貼上、貼到「資料夾」」；對單檔、資料夾、多選都適用。Finder 拷貝的檔案可直接貼到裝置；Mac 項目拷貝後可貼到 Finder |
| 刪除 | Delete 鍵或右鍵；Mac 為移到垃圾桶，裝置為永久刪除（含資料夾內容），皆會確認 |
| 窗格互傳 | 右鍵「複製／移動到另一窗格」、拖放（窗格 ⇄ 窗格、Finder ⇄ 窗格）；同 Finder：同一來源拖放為移動（原生 mv），按住 Option 為拷貝，不同來源及 Finder 拖入為拷貝 |
| 傳輸引擎 | 同來源原生 cp／mv；跨來源經 Mac 暫存區中繼；剪下 = 複製成功後才刪來源；同名自動改名（`a 2.txt`）；進度、可取消、取消時清掉不完整檔案 |
| 檔案操作 | 新增資料夾/檔案、改名、權限（Android chmod）、遞迴搜尋（Android）、書籤（Android）、排序、篩選 |
| 編輯器 | 任一來源的文字檔：語法上色、⌘F／⌥⌘F、undo、編碼偵測與切換、無損存檔 |
| Android 工具 | 終端機（多分頁）、App 管理、裝置資訊、重開機、截圖、寫入剪貼簿、scrcpy 鏡像、無線配對／連線（工具列選擇目標裝置） |

## 安裝（另一台 Mac）

```bash
git clone <repo> SmartphoneFileManager && cd SmartphoneFileManager
./tools/install.sh            # 檢查需求、詢問選用相依、測試、組 app、安裝到 /Applications
```

詳見 [`INSTALL.md`](INSTALL.md)。

## 開發

```bash
swift test                                            # 單元測試（40 項）
SFM_LIVE=1 swift test --filter LiveDevice             # 實機整合測試（需 Android + iPhone）
./tools/make-app.sh && open .build/SmartphoneFileManager.app
open Package.swift                                    # Xcode 開發／除錯
```

## 目錄結構

```
Package.swift                 SwiftPM（L1 SFMCore + L4 App + 測試）
Sources/SFMCore/              L1：零 UI 相依，可 swift test
  Process/ProcessRunner       子行程唯一入口（可取消、逾時、串流、不經 shell、不依賴 run loop）
  Adb/                        AdbClient/DeviceConnection、AdbLocator、ShellText 跳脫、Tokenizer
  Sources/                    FileSource 抽象 + Mac／Android／iPhone 實作、FileTransfer 傳輸引擎
  Model/                      FileItem、StatParser、SortType、TextCodec、Bookmark
  Services/                   AppPackage／DeviceInfo／Clipboard／Scrcpy（Android 工具）
  Terminal/                   AdbShellSession（FSM）、ShellOutputFilter、補完
Sources/SmartphoneFileManager/ L4：SwiftUI app
  App/AppModel                協調者：來源解析、剪貼簿、傳輸、拖放、開啟
  Browser/                    BrowserModel（窗格狀態，左右共用）、BrowserPaneView、對話框
  Setup/                      SetupGuideView（安裝導引）
Tests/SFMCoreTests/           Swift Testing（含 FakeSource 引擎測試、實機測試）
Localization/                 *.lproj（tools/gen-strings.py 產生：繁中＝zh-Hant.json 人工維護；簡中＝hant2hans.swift 自動轉換＋overrides）
vendor/                       adb、clipboard-helper.dex.b64
tools/                        install.sh、make-app.sh、make-icon.swift、AppIcon.icns、gen-strings.py、hant2hans.swift、zh-Hant.json、zh-Hans.overrides.json
```

## 狀態

- `swift build` 零警告；`swift test` 40/40；實機整合測試（Palma Android + iPhone iOS 27）通過。
- 已截圖確認：左 iPhone／右 Android 雙窗格瀏覽。
- 待手動驗收：UI 上的 ⌘C/⌘X/⌘V、拖放、拖到 Finder（file promise，best-effort）。

設計取捨見 [`BACKGROUND.md`](BACKGROUND.md)，更動紀錄見 [`LOG.md`](LOG.md)。
