# Smartphone File Manager（macOS）

在 Mac 上同時管理 **Mac、Android、iPhone** 檔案的雙窗格檔案管理器，以 **Swift 6 + SwiftUI** 撰寫。
源自 [wkbin/AdbFileManager](https://github.com/wkbin/AdbFileManager)（Kotlin/Compose）的 macOS 移植，
並擴充為任意來源 ⇄ 任意來源。結構：SwiftPM 套件 + `tools/make-app.sh`。

- **部署目標**：macOS 14+（開發機 macOS 27 / Xcode 27 / Swift 6.4）
- **Android**：需要 adb（`brew install --cask android-platform-tools` 或 Android SDK）；`make-app.sh` 會把找到的 adb 內附進 .app。
  repo 不收錄 adb 二進位檔（Google SDK 授權條款），見 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
- **MTP**（必要相依 `brew install libmtp`）：沒開 USB 偵錯的 Android、電子書閱讀器等 MTP 裝置；有 adb 的 Android 也可另選 MTP。
  根目錄列出各儲存空間（內部、SD 卡）；同儲存空間移動與小檔複製由裝置端完成，大檔／資料夾經 Mac 中繼（MTP 裝置端複製無進度且會逾時）
- **iPhone**：USB 或 **Wi-Fi**（先以 USB 接一次、在 Finder 開啟「在 Wi-Fi 上時顯示此 iPhone」，之後同網路即可；USB 與 Wi-Fi 同時存在時用 USB）。透過 libimobiledevice（`brew install libimobiledevice ideviceinstaller`）。根目錄分兩個虛擬資料夾：
  `Media`（DCIM、Downloads、Books…）與 `Apps`（開啟檔案分享的 App 及其 Documents，等同 Finder 的「檔案」分頁）
- **發佈**：自用、ad-hoc 簽章、App Sandbox 關閉；**語系**：English／繁體中文／简体中文（跟隨系統語言）
- **安裝導引**：缺 adb、libimobiledevice、scrcpy 時於 app 內顯示步驟、官方下載連結與一鍵安裝指令（輔助說明 → 安裝導引）

## 畫面

![主畫面：左窗格 iPhone App 文件、右窗格 Android](docs/screenshots/main.png)

**工作面板**：底部可收合，樹狀展開到檔案；同一台裝置的工作依序執行（第二個排隊中）

![工作面板：進行中與排隊中的工作，展開到檔案層級的進度](docs/screenshots/tasks.png)

**工作佇列**：暫停的工作保留進度；展開到檔案可見已完成 ✓、中斷待續傳（橘色）、等待中 ○，按繼續從中斷處續傳

![工作佇列：已暫停、已完成的工作，檔案層級的狀態](docs/screenshots/queue.png)

**衝突對話框**：目的已有同名檔案時並列大小與日期；目的較小時可從中斷處續傳

![衝突對話框：續傳／覆寫／保留兩者／略過](docs/screenshots/conflict.png)

（截圖中的裝置序號、裝置名稱、開發者 ID 與個人檔名已打馬賽克）

## 功能

| 區塊 | 說明 |
|---|---|
| 雙窗格、任意來源 | **左右窗格各自**以標題的來源按鈕選擇：這台 Mac、任一 Android、任一 iPhone；同一台裝置可在兩邊同時開不同資料夾。來源與各來源最後所在資料夾都會記住，下次啟動恢復（裝置未連線時等它連上；資料夾已不存在則回起始資料夾） |
| 拷貝／剪下／貼上 | 表格焦點時 ⌘C／⌘X／⌘V；右鍵「拷貝、剪下、貼上、貼到「資料夾」」；對單檔、資料夾、多選都適用。Finder 拷貝的檔案可直接貼到裝置；Mac 項目拷貝後可貼到 Finder |
| 刪除 | Delete 鍵或右鍵；Mac 為移到垃圾桶，裝置為永久刪除（含資料夾內容），皆會確認 |
| 窗格互傳 | 右鍵「複製／移動到另一窗格」、拖放（窗格 ⇄ 窗格、Finder → 窗格、Mac 窗格 → Finder；裝置檔案存到 Mac 用「匯出」或拖到 Mac 窗格）；同 Finder：同一來源拖放為移動（原生 mv），按住 Option 為拷貝，不同來源及 Finder 拖入為拷貝 |
| 工作佇列 | 拷貝／移動／刪除都進入底部「工作」面板（可收合、可調高度）：樹狀展開到檔案、各自進度；暫停／繼續／停止／移除；每台裝置一次一個工作（不同裝置並行）；**關閉 app 後保留**，重開時為暫停、按繼續才執行 |
| 衝突與續傳 | 目的已有同名檔案時詢問（類似 FTP）：並列兩邊大小與日期，可選續傳／覆寫／保留兩者／略過，可套用到其餘衝突；資料夾同名則合併。大檔從中斷處續傳：Android（`tail -c`／`exec-in`／`dd`）、MTP（Partial Object）、Mac；iPhone（AFC 無法指定位置）一律重傳 |
| 傳輸路徑 | 同裝置同檔案系統為原生 mv（瞬間）；其餘逐檔傳輸：同裝置原生 cp（不經 Mac）、跨裝置經 Mac 中繼（暫存於 Application Support，可續傳）；跨檔案系統搬移會預檢空間 |
| 檔案操作 | 新增資料夾/檔案、改名、權限（Android chmod）、路徑列右鍵拷貝路徑、遞迴搜尋（Android）、書籤（Android）、排序（點名稱／大小／修改日期欄位標題，或排序選單）、篩選 |
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
swift test                                            # 單元測試（51 項，含預設略過的實機測試）
SFM_LIVE=1 swift test --filter LiveDevice             # 實機整合測試（需 Android + iPhone）
SFM_LIVE=1 swift test --filter MTPLive                # MTP 實機測試（需 MTP 裝置）
./tools/make-app.sh && open .build/SmartphoneFileManager.app
open Package.swift                                    # Xcode 開發／除錯
```

## 目錄結構

```
Package.swift                 SwiftPM（L0 CLibMTP + L1 SFMCore + L4 App + 測試）；找不到 libmtp 即停止建置
Sources/CLibMTP/              L0：libmtp 標頭的 C 模組（弱連結）
Sources/SFMCore/              L1：零 UI 相依，可 swift test
  Process/ProcessRunner       子行程唯一入口（可取消、逾時、串流、不經 shell、不依賴 run loop）
  Adb/                        AdbClient/DeviceConnection、AdbLocator、ShellText 跳脫、Tokenizer
  Sources/                    FileSource 抽象（含續傳介面 ResumableTransfer）+ Mac／Android／iPhone／MTP 實作
  MTP/                        MTPSession（每台裝置一條序列佇列）、MTPDeviceManager（偵測／開啟／釋放）
  Queue/                      工作佇列：TransferJob（模型與 FSM）、TransferPlanner（展開樹）、
                              TransferExecutor（逐節點執行、衝突、續傳）、TransferQueue（排程、持久化）
  Model/                      FileItem、StatParser、SortType、TextCodec、Bookmark
  Services/                   AppPackage／DeviceInfo／Clipboard／Scrcpy（Android 工具）
  Terminal/                   AdbShellSession（FSM）、ShellOutputFilter、補完
Sources/SmartphoneFileManager/ L4：SwiftUI app
  App/AppModel                協調者：來源解析、剪貼簿、加入工作佇列、拖放、開啟
  Queue/                      TasksPanel（底部工作面板）、ConflictSheet（衝突對話框）
  Browser/                    BrowserModel（窗格狀態，左右共用）、BrowserPaneView、對話框
  Setup/                      SetupGuideView（安裝導引）
Tests/SFMCoreTests/           Swift Testing（含 FakeSource 引擎測試、實機測試）
docs/                         README 截圖（docs/screenshots，敏感資料已打馬賽克）
Localization/                 *.lproj（tools/gen-strings.py 產生：繁中＝zh-Hant.json 人工維護；簡中＝hant2hans.swift 自動轉換＋overrides）
vendor/                       clipboard-helper.dex.b64（adb 可本機放置於此，不收錄於 repo）
tools/                        install.sh、make-app.sh、make-icon.swift、AppIcon.icns、gen-strings.py、hant2hans.swift、zh-Hant.json、zh-Hans.overrides.json
```

## 狀態

- `swift build` 零警告；`swift test` 51/51；實機整合測試（Palma Android + iPhone iOS 27）通過。
- 已截圖確認：左 iPhone／右 Android 雙窗格瀏覽。
- 待手動驗收：UI 上的 ⌘C/⌘X/⌘V、拖放。

第三方來源與授權見 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)（MIT；源自 wkbin/AdbFileManager）。

設計取捨見 [`BACKGROUND.md`](BACKGROUND.md)，更動紀錄見 [`LOG.md`](LOG.md)。
