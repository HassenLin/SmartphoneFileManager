# LOG

- 2026-10-16｜**建置需要完整 Xcode：自動選用 Xcode 工具鏈**
  - 另一台 Mac pull 後編譯失敗：`plugin for module 'SwiftUIMacros' not found`。新版 SDK 的 SwiftUI 以巨集實作 `@State` 等，
    巨集外掛 `libSwiftUIMacros.dylib` 只在 Xcode 內（Command Line Tools 沒有）；該機 xcode-select 指向 Command Line Tools 或未裝 Xcode。
  - 新增 `tools/xcode-env.sh`（`make-app.sh`、`install.sh` 載入）：xcode-select 未指向 Xcode.app 時，找到 Xcode 即只對該次建置設定
    `DEVELOPER_DIR`（不需 sudo），找不到則說明需安裝 Xcode。INSTALL.md 更新需求說明。

- 2026-10-16｜**iPhone Wi-Fi 連線**
  - 偵測同時列出 USB（`idevice_id -l`）與 Wi-Fi（`idevice_id -n`）裝置，同一支兩邊都有時用 USB；以 UDID 識別，拔掉 USB 後自動改走 Wi-Fi。
  - Wi-Fi 裝置呼叫 `afcclient`／`ideviceinfo`／`ideviceinstaller` 時加 `-n`；來源選單標示「(Wi-Fi)」；未連線畫面說明在 Finder 開啟 Wi-Fi 顯示。

- 2026-10-16｜**工作佇列（樹狀、暫停／繼續／停止、關閉 app 後可繼續）、衝突對話框、續傳**
  - SFMCore 新增 `Queue/`：`TransferJob`（模型與 FSM：pending／running／waitingForUser／paused／completed／failed／stopped）、
    `TransferPlanner`（同裝置同檔案系統移動不展開；其餘展開到檔案）、`TransferExecutor`（逐節點、衝突詢問、續傳、移動逐檔刪來源）、
    `TransferQueue`（每台裝置一次一個工作、`queue.json` 持久化；重開 app 一律暫停，執行中的檔案轉為 partial）。取代舊的 `FileTransfer`。
  - `FileSource` 新增 `stat`／`moveIsInstant`／`resumeDownload`／`resumeUpload`／`resumeCopy`（預設整份重傳）與 `capabilities.resumable`。
    Android：新傳輸照用 pull／push／cp，有部分內容時改走 `exec-out tail -c +N`、`exec-in cat >>`、`truncate`＋`dd conv=notrunc`；
    MTP：Get Partial Object、Begin/Send Partial/End Edit Object；Mac：分塊附加寫入；iPhone 不支援。
  - 實測陷阱：`Process` 不沿用 FileHandle 的讀取位置（子行程總從檔頭讀），續傳上傳改以 macOS `tail -c +N` 管線餵 `adb exec-in`。
  - 衝突對話框（`ConflictSheet`）：並列大小（含位元組數）與修改日期；續傳／覆寫／保留兩者／略過；套用到此工作的其餘衝突。
    資料夾同名合併不詢問；同資料夾複製比照 Finder 自動改名；自己中斷的檔案繼續時直接續傳。
  - UI：底部可收合、可調高度的 `TasksPanel`（OutlineGroup 樹）；刪除與匯出也走佇列。`TransferCenter` 只留開啟檔案／安裝 APK（類別改名 `ActivityJob`）。
  - 測試：佇列 13 項（含暫停後「重開」再繼續、停止清除、衝突四種動作、套用全部、每裝置一個工作），連跑 5 次穩定；
    實機：Android 三種續傳、MTP 下載／上傳續傳（MD5／內容比對）；`LiveDevice` 端對端改走佇列。單元測試共 51 項。

- 2026-10-16｜**修正：傳輸期間視窗無法操作**
  - 原因：進度以 sheet（強制回應）顯示，整個傳輸期間擋住視窗；且 `TransferCenter` 一次只允許一個工作，傳輸中發起的新操作被默默忽略。
  - 改為視窗底部的非強制回應 `TransferPanel`：可同時多個工作、各自進度與取消；同一台 MTP 裝置的工作由 session 佇列自然排隊。
  - 新增 `ProgressCoalescer`：高頻進度回報（libmtp 每個 USB 區塊一次）合併成主執行緒同時最多一個更新。
  - 補上 MTP 裝置清單變動時更新窗格（原本只監看 Android／iPhone）。
  - 修正：窗格間拖放卡住（藍框出現後整個 app 無回應、選單不能按）。兩個原因：
    1. 裝置項目附帶「拖到 Finder 用」的檔案表示法，系統在拖曳經過放下目的地時就要求它準備好（須整份下載）；
       立即下載、拒絕、延後回應都會卡住。改為裝置項目不附帶；拖曳開始時記錄於 `activeDrag`，
       窗格以 `PaneDropDelegate` 直接完成放下（不載入拖曳資料），游標依同來源／Option 顯示移動或拷貝。
       代價：裝置檔案不能直接拖到 Finder（改用「匯出」或拖到 Mac 窗格）。
    2. 藍框狀態原為窗格的 `@State`，一變整個窗格（含數百列表格）重算、底層拖放目的地 view 被重建，
       AppKit 在左右窗格間反覆送出進入／離開（日誌實證），主執行緒被重算塞滿。改為獨立的 `DropTargetState`
       （只由藍框讀取）且藍框只切換透明度、不改 view 結構；修正後進出順序與滑鼠路徑一致。
  - 拖放流程加入日誌（subsystem `idv.hassen.smartphonefilemanager`、category `drag`），便於現場除錯。

- 2026-10-16｜**adb 不再收錄於 repo（開源準備）**
  - `vendor/adb`（Google SDK Platform-Tools 二進位，再散布受 Android SDK 授權條款約束）移出 repo 並列入 `.gitignore`，
    並自 git 歷史中移除（尚未推送前改寫）。
  - `make-app.sh`：依序取本機 `vendor/adb`、系統 adb（Homebrew／Android SDK／PATH）內附進 .app；都沒有則不內附（app 自動改用系統 adb）。
  - `install.sh`：沒有 adb 時以 Homebrew 安裝 `android-platform-tools`。

- 2026-10-16｜**MTP 支援（libmtp）、第三方聲明**
  - 新增 `MTPFileSource`：虛擬根目錄列出儲存空間；路徑 ⇄ 物件 ID 快取於 session。
    `MTPSession` 每台裝置一條序列佇列（libmtp 非執行緒安全、MTP 一次一個交易）；`MTPDeviceManager` 以 USB 位置辨識、
    開啟失敗（被 Android File Transfer／OpenMTP／影像擷取佔用）15 秒後重試。
  - 裝置內操作：同儲存空間移動用 Move Object；≤256MB 單檔的複製／跨儲存空間移動用 Copy／Move Object；
    其餘經 Mac 中繼（MTP 裝置端複製無進度，且 USB 交易逾時 20～60 秒，大檔會在裝置仍在寫入時逾時）。
  - libmtp 為固定（必要）相依：Package.swift 找不到 libmtp.h 即停止建置；以 `-weak-lmtp` 弱連結，
    執行時缺 libmtp 仍可啟動並提示安裝。`install.sh` 自動安裝 libmtp。
  - 新增 `THIRD_PARTY_NOTICES.md`（開源用來源與授權清單；內附 adb 二進位的再散布授權列為待決）；`LICENSE` 加上本專案著作權行。
  - 實機測試 `MTPLive`（Palma：內部共用儲存空間 + SD 512G）通過：上傳（有進度）、下載比對、改名、移動、裝置端複製、中繼複製、跨儲存空間移動、遞迴刪除。
  - 已知：建置時 ld 警告 libmtp.dylib 為較新 macOS 編譯（Homebrew bottle 依本機系統），不影響執行。

- 2026-10-16｜**移動／複製顯示進度、空間預檢、拖曳誤下載修正、路徑列拷貝路徑**
  - `FileSource.move` 新增 `onProgress`（另有不帶進度的便利多載供改名使用）。
    Android：`stat -L -c %d` 判斷跨檔案系統（內部儲存 ⇄ SD 卡，`mv` 實為整份複製），
    此時 `du -sk` 取來源大小、執行中每 0.5 秒 `du -sk` 目的端回報進度；iPhone 媒體區 ⇄ App 的中繼移動接上下載／上傳進度。
  - 跨檔案系統移動前以 `df -k` 檢查目的地剩餘空間，不足即報錯不開始
    （實際案例：20.4G 檔案搬到只剩 14G 的 SD 卡，原本只有不確定進度列，看似當掉）。
  - 路徑列右鍵「拷貝路徑」：點某一段拷貝到該層，點空白處拷貝目前完整路徑。
  - 修正：窗格間拖曳裝置上的大檔案時停在藍框。拖到 Finder 用的檔案表示法（下載到 Mac 暫存區）
    在滑鼠進入另一窗格時就被 SwiftUI 要求，20G 檔案因此開始下載到 `$TMPDIR`。
    改為滑鼠仍在本 app 視窗上時拒絕提供，窗格間只走自有型別（同裝置 → 原生 mv）。
  - 複製也有進度：`FileSource.copy` 新增 `onProgress`。Android 同裝置 `cp -r`（不經 Mac）與跨檔案系統 mv
    共用 `runTracked`（`du`／`df` 空間預檢 + 輪詢目的端大小）；Mac 本機複製輪詢目的端大小（8MB 以上）。
    iPhone 內複製仍須經 Mac：AFC 沒有 copy 指令。
  - 啟動時清除上次留下的 `afm-*` 暫存（`afm-open-*` 可能仍被其他 App 開著，超過一天才清）。
  - 修掉 `IPhoneFileSource.run(_:_:)` 未使用回傳值的既有警告（補 `@discardableResult`）。
  - 新增實機測試 `androidNativeCopyAndMoveReportProgress`（256MB cp 與 mv 內部儲存 → SD 卡，皆有中間進度；
    內部儲存內 cp 256MB 僅 0.48 秒，快於輪詢間隔，故測 SD 卡）；`swift test` 41 項通過。

- 2026-10-16｜**欄位標題排序、記住各窗格路徑**
  - 表格原本未綁定 `sortOrder`，點標題不會排序。新增 `FileColumnComparator`（標題 ⇄ `SortType` 轉接，
    排序真相仍是 `BrowserModel.sortType`，與排序選單共用）；「類型」排序沒有對應欄位，標題不顯示箭頭。
  - `BrowserModel` 以 UserDefaults `panePaths.<side>`（`kind:deviceID` → 路徑）記住每個來源最後的資料夾，
    啟動與切換來源時恢復；恢復的資料夾載入失敗則退回起始資料夾（只退一次）。來源本身原已記住（`paneSource.<side>`）。
  - 驗證：寫入存在／不存在的路徑後重啟，前者恢復、後者退回 `/sdcard`。

- 2026-10-16｜**修正：多選刪除確認視窗當機（中文語系）**
  - 「Delete %lld items from %@?」的翻譯調換了參數順序卻未寫位置編號（`要從 %@ 刪除 %lld…`），
    `%@` 拿到整數（項目數）被當物件指標讀取 → `EXC_BAD_ACCESS`。改為 `%2$@`／`%1$lld`。
  - `tools/gen-strings.py` 新增格式參數檢查：翻譯的參數位置／型別與原文不符即中止產生。

- 2026-10-16｜**同一裝置拖放改為移動**
  - 原本拖放一律為拷貝（`handleDrop` 寫死 `move: false`），左右窗格同一台 iPhone 互拖時會經 Mac 讀出再寫回。
    改為與 Finder 相同：同一來源預設移動（`FileTransfer` → `source.move`，原生 mv），按住 Option 為拷貝；
    不同來源、Finder 拖入的檔案仍為拷貝（不搬走 Finder 原檔）。
  - 限制：iPhone 媒體區 ⇄ App、App ⇄ App 屬不同 AFC 服務，沒有原生 mv，仍需經 Mac 中繼。

- 2026-10-16｜**工作區搬家**：`AdbFileManager/` → `SmartphoneFileManager/`
  （以 ditto 複製，Claude Code session／記憶一併複製；採「先複製、驗證後再刪舊目錄」，不再用改名腳本）。
  - 驗證：工作樹乾淨、檔案數一致（472，不含 `.build`）；新路徑重建後 `swift test` 40 項通過，`make-app.sh` 組出 app 可啟動。

- 2026-10-16｜**iPhone App 文件、安裝導引、簡體中文**
  - iPhone 改為虛擬樹：`/Media`（AFC 媒體區）＋ `/Apps`（house_arrest，可分享檔案的 App 的 Documents；清單來自 `ideviceinstaller`，快取 2 分鐘）。
    媒體區 ⇄ App、App ⇄ App 之間沒有原生 mv，自動經 Mac 中繼。虛擬層受保護。
  - 實機測試抓到：`/x` 這類不在 Media／Apps 下的路徑原本退回「當作媒體區」，導致在 iPhone 媒體區根目錄真的建了空資料夾 `x`；
    已移除該退路（改為 `.invalid` 一律拒絕），並刪除誤建的 `x`。
  - 新增安裝導引（SetupGuideView）：偵測 adb／Homebrew／libimobiledevice／ideviceinstaller／scrcpy，提供步驟、官方連結、
    拷貝或「在終端機執行」安裝指令；adb 無法執行時啟動即自動開啟。
  - 新增簡體中文：`tools/hant2hans.swift` 自繁中轉換（大陸用語對照單次最長匹配＋ICU Hant-Hans＋「」→“”），`zh-Hans.overrides.json` 人工覆寫。
  - `install.sh` 一併安裝 ideviceinstaller。測試 40 項＋實機整合測試通過。

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
