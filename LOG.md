# LOG

- 2026-10-19｜**修正 pCloud 上傳顯示「uploadfile: unexpected response」**：`uploadfile` 回應的 `metadata` 是陣列（其他方法是物件），
  解碼失敗把成功的上傳當成錯誤。`PCloudClient.Envelope` 改為兩種都接受、其餘欄位寬鬆解碼；解碼失敗時錯誤訊息附上回應開頭。測試 108 項通過。

- 2026-10-19｜**主執行器一律多連線**：連線數改由執行器決定（`ExecutorLane`：主＝大檔同時連線數、子＝1），不再看檔案大小；
  大小只用來分流。同時傳輸數 1 時唯一的執行器即主執行器，每個下載都多連線。小於兩個區塊（8 MiB）的檔案切不開，
  WebDAV／pCloud 直接單一請求（省掉 Range 探測）。測試 107 項通過。

- 2026-10-19｜**主執行器（大檔、多連線）＋子執行器（小檔）**
  - 佇列依檔案大小分流：同時傳輸數 N ≥ 2 時 1 個主執行器專給 ≥ 大檔門檻（預設 200 MB，帳號選項可調）的檔案、N−1 個子執行器傳小檔；
    只有主執行器會多連線（`ExecutorLanes`、`TransferExecutor.runLevel`）。大檔在背景等主執行器，不擋住後面的小檔。N = 1 時唯一執行器即主執行器。
  - 「最大同時連線數」改為「大檔同時連線數」：`FileSource.resumeDownload(…connections:)` 由執行器決定連線數。
    WebDAV／pCloud：`SegmentedDownload`（8 MiB 區塊、多連線 Range、隱藏狀態檔續傳、可從單一連線前段接續；WebDAV 先探測 Range 支援）；
    FTP／SFTP：`pget -c -n`，進度解析 `.lftp-pget-status`。上傳不分段。Mac 端停止時清除狀態檔。HTTP 連線池＝(N−1)＋大檔連線數。
  - 選項視窗新增「並行傳輸」段落（同時傳輸數、大檔門檻、大檔同時連線數）。
  - 測試 107 項通過（新增：大小分流、單一執行器即主執行器、分區塊下載／續傳／前段接續、pget 狀態檔、選項）；
    本機實測 FTP（pyftpdlib，pget 4 條連線）與 WebDAV（wsgidav）20 MiB 多連線下載與前段接續，內容一致。

- 2026-10-18｜**網路帳號可並行上傳／下載多個檔案（帳號選項「同時傳輸數」）**
  - `ConnectionOptions.parallelTransfers`（預設 1，可在帳號選項或 設定 → 網路 全域預設調整，1～8）；HTTP 連線池至少容納同時傳輸數。
  - `FileSource.maxParallelTransfers`（預設 1；WebDAV／FTP／SFTP／pCloud 取自選項）；工作的並行數取涉及的非 Mac 來源中最小者。
  - `TransferSlots`（可取消的計數號誌）＋ `TransferExecutor.runLevel`：單檔取得名額後在背景傳，資料夾等其他節點依序執行；
    本層全部完成才回報，移動時父資料夾據此刪除來源。暫停時所有進行中的檔案轉 partial。
  - 衝突：並行時同工作可能同時有多個衝突，「套用到全部」一併回答已排隊的衝突；全部答完才回到執行中。
  - 工作列「目前：檔名 等另外 N 個」。測試 99 項通過（新增：巢狀資料夾名額上限、手機端維持逐檔、並行中暫停後繼續）。

- 2026-10-18｜**工作佇列：立即開始，顯示百分比與預估完成時間（目前作業優先）**
  - `TransferPlanner` 不再於開始前遞迴列出整棵資料夾樹：資料夾節點標 `expanded == false`，`TransferExecutor` 執行到時才列出一層
    （`NodeEvent.expand`，寫入佇列保存，繼續時不必重列）。第一個檔案立刻開始傳。同步仍事先比對展開。
  - 新增 `TransferRate`（1 秒視窗＋指數移動平均，只計實際傳輸的增量）與 `DurationFormat`；佇列保存每個執行中工作的速率。
  - 工作列：百分比、已傳／總量、預估剩餘時間（仍在掃描時為「至少剩 …（仍在掃描）」）；下一行「目前：檔名 百分比 · 速率 · 剩 …」。
  - 測試 96 項通過（新增：規劃不列資料夾、一層展開、速率平滑、時間格式）。

- 2026-10-18｜**pCloud 改為 Email＋密碼登入（不需註冊 pCloud App）**
  - 原本只能 OAuth，須先在 pCloud 註冊 App 取得 Client ID／Secret 並等核准。新增 `PCloudLogin`：`getdigest`＋`passworddigest`
    （密碼不送出、不儲存）換 auth token；兩步驟驗證（2297 → `tfa_login`）；先試選定地區、失敗再試另一區，自動判定美國／歐洲。
  - `PCloudToken` 區分 session（`auth=` 參數）與 OAuth（Bearer）；鑰匙圈以 `session:` 前綴區分，舊 OAuth token 相容。
  - 帳號設定的 pCloud 區塊改為 Email／密碼／驗證碼；設定 → 網路 的 OAuth 標為選用，有填 Client ID 才顯示「用瀏覽器登入」。
  - 登出／刪帳號時呼叫 `logout` 作廢 token（複製出的帳號共用 token 時不作廢）。測試 93 項通過；尚未以實際 pCloud 帳號驗證。
  - 修正：開了兩步驟驗證的帳號沒有出現驗證碼欄位 → 改用 `login` 方法並帶 `os`／`deviceid`（官方文件未記載，依 pcloudcom/console-client 與 seborama/pcloud SDK），
    2297 時以 `tfa_login`＋6 位數驗證碼換 token，`trustdevice=1` 之後此 Mac 不必再輸入。
  - 修正：輸入 6 位數驗證碼後按 Return 觸發的是「儲存」，重建畫面後驗證狀態遺失、回到輸入密碼 → pCloud 登入中 Return 改對應「登入」／「驗證」；
    pCloud 密碼欄不算未儲存變更；token 寫入鑰匙圈失敗時顯示錯誤。
  - 修正：在錯的資料中心登入回 2321（This user is on another location）時沒有換區重試 → 2321 改為自動改試另一區。
  - 實機驗證：歐洲帳號以 Email＋密碼＋6 位數驗證碼登入成功。

- 2026-10-18｜**`make-app.sh` 改用固定簽章身分：重新 build 不必再允許鑰匙圈存取**
  - 回報「FTP 密碼沒存進鑰匙圈」：實際有存，是 ad-hoc 簽章每次 build 的 cdhash 不同，macOS 把新 build 視為別的 app 而要求重新允許。
  - 改為優先用有效的 Apple Development 憑證簽章（濾掉已撤銷者；`SFM_SIGN_IDENTITY`／`SFM_SIGN_TEAM` 可指定），權限改綁 bundle id＋憑證；找不到才退回 ad-hoc。

- 2026-10-18｜**從 Finder 拖檔案或資料夾到路徑列：開啟該 Mac 路徑**
  - `PathBar` 加 `dropDestination(for: URL.self)`（只收檔案網址，裝置／網路項目不受影響），放下時藍框提示。
  - `AppModel.openMacLocation`：窗格不是 Mac 時先切到這台 Mac；資料夾直接開啟，檔案開啟所在資料夾並選取。

- 2026-10-18｜**新增網路來源：WebDAV、FTP／FTPS（主動／被動、explicit／implicit）、SFTP、pCloud（美國／歐洲）**
  - 架構：`SourceID.Kind.network`（deviceID＝帳號 id），協定 → 實作只在 `NetworkSourceFactory`；佇列、衝突、續傳、同步、書籤不需修改。
  - 帳號：`NetworkAccount`＋`ConnectionOptions`（每欄可覆寫全域預設），存 `Application Support/…/accounts.json`；密碼／token 存鑰匙圈（`CredentialStore`，
    主機／帳號變更時搬移密碼）。
  - UI：帳號清單視窗（⌥⌘K）、帳號設定（測試連線、憑證釘選、pCloud 登入）、選項視窗；設定 → 網路（全域預設、pCloud App）；來源選單、窗格錯誤畫面、安裝導引（lftp）。
  - WebDAV：移植 nas_webdav 用戶端並 async 化；Range 續傳下載、部分寫入探測續傳上傳、MOVE／COPY 伺服器端完成。
  - FTP／SFTP：lftp 子行程。實測發現 lftp 4.9.3＋OpenSSL 3 在 TLS 1.3 上傳會截斷 → FTPS 以 `OPENSSL_CONF` 限 TLS 1.2，上傳後驗證大小。
    SFTP 主機金鑰記在 app 專用 known_hosts（路徑含空白需再包雙引號，否則 ssh 切成多個檔案）。
  - pCloud：OAuth2 loopback（127.0.0.1:53682），依回呼 hostname／locationid 決定地區並以對應 host 換 token。
  - 測試 92 項通過（新增 28 項）；網路實機測試以本機 pyftpdlib／wsgidav／asyncssh 伺服器通過（FTP 被動／主動、FTPS 兩種、SFTP、WebDAV）。
  - 待驗收：Synology https WebDAV、pCloud 實際帳號登入、UI 端到端操作。

- 2026-10-16｜**書籤選單依窗格目前的裝置篩選**
  - 資料夾書籤只列此裝置的（舊版「任一台 Android」書籤列在每一台 Android）；同步專案列任一邊在此裝置的。
  - 其他裝置的書籤與同步專案收在「其他裝置（N）」子選單，未連線裝置的項目仍可開啟或刪除。
  - 判斷規則在 core（`FolderLocation.belongs(to:)`、`SyncProject.involves`），新增測試，共 64 項通過。

- 2026-10-16｜**同步方向改「左 ← 右」，新增雙向同步「左 ↔ 右」；移除窗格的新增資料夾獨立按鈕**
  - 雙向：先一次比對兩邊再執行（`SyncPlanner.twoWayDiff`），較新的一方覆蓋另一方、只在一邊的拷到另一邊；
    右 → 左的節點標 `reversed`，執行器以對調來源／目的的執行器處理。拆成兩個單向工作會出錯：裝置無法保留修改時間，第二趟會把剛傳過去的檔案判為較新而傳回。
  - 分不出新舊（大小不同、時間相近或沒有時間）與「檔案 ↔ 資料夾同名」：不動，標為略過並說明。雙向不刪除（沒有上次同步紀錄，無法分辨刪除與新增）。
  - Mac ↔ Mac 雙向：兩趟 `rsync -a --update`（rsync 保留時間，第二趟不會回傳）。
  - 新增資料夾已有（＋選單、右鍵、⇧⌘N），移除上一版加的獨立按鈕。
  - 測試 63 項通過（雙向較新者勝、無法判斷時略過、實際執行系統 rsync 雙向）。

- 2026-10-16｜**書籤兩種（資料夾書籤、同步專案）＋類似 rsync 的同步**
  - 書籤庫 `BookmarkLibrary`（Application Support/bookmarks.json）：資料夾書籤含來源（任何裝置都可用，原本只有 Android）、同步專案（左右資料夾、方向、選項）。
    首次匯入舊版 Android 書籤（無裝置序號 → 開啟時用窗格目前或第一台 Android）；舊檔不修改。
  - 同步為工作佇列的新工作種類 `.sync`：規劃時比對（`SyncPlanner`：新增、大小不同或來源較新才傳；可刪除多餘），
    新節點 `.deleteTarget`；需要更新的同名檔一律覆寫（工作預設衝突策略 overwrite）。
    無法跨來源保留修改時間，所以比對用「來源較新」（容許 2 秒）而非 rsync 的「時間不同」。
  - 兩邊都是 Mac：單一 `.rsync` 節點執行 rsync（`RsyncCommand`，`-a --itemize-changes`，系統 openrsync 與 Homebrew rsync 3 的延伸屬性參數不同，自動判斷）。
    其他組合依能力（`SyncCapabilities`）只顯示做得到的選項。
  - 工具列「同步」彈出視窗：專案名稱、方向、選項、取消／儲存／同步（同步前若有變更先儲存）。
  - 測試 60 項通過（同步規劃、重複同步無動作、重疊拒絕、rsync 參數、實際執行系統 rsync）。

- 2026-10-16｜**工具列改為 Android／iPhone 彈出視窗；新增 iPhone 工具、Mac 雲端硬碟位置、新增資料夾快捷**
  - 工具列原本一排 Android 工具按鈕＋裝置選單，改為「Android」「iPhone」兩顆按鈕，各自彈出視窗（目標裝置選擇＋工具清單）。
    共用 `DeviceToolsButton`；點工具時先關 popover 再開 sheet，避免兩個呈現同時發生。
  - iPhone 工具（`IPhoneDeviceService`，libimobiledevice）：裝置資訊（ideviceinfo 預設／battery／disk_usage 網域）、
    重新開機／關機（idevicediagnostics）、App 清單／安裝 .ipa／解除安裝（ideviceinstaller）。
    截圖不提供：實測 iOS 27 `idevicescreenshot` 回 `Invalid service`（iOS 17 起需 CoreDevice 通道）。
  - Mac 窗格加「位置」選單：iCloud 雲碟、`~/Library/CloudStorage/*`（Google Drive、OneDrive…）、`/Volumes/*`；這些藏在隱藏的 ~/Library 下，原本瀏覽不到。
  - 新增資料夾：窗格標題列獨立按鈕；檔案選單 ⇧⌘N 作用在最後操作的窗格（`AppModel.activeSide`）。
  - 測試 54 項通過（新增 ideviceinfo／App 清單／雲端名稱解析）；組 app 後確認 iPhone 彈出視窗可列出 Wi-Fi 連線的 iPhone。

- 2026-10-16｜**修正：暫停後資料夾節點仍顯示轉圈；補工作佇列截圖**
  - 暫停時只把中斷的檔案節點轉為 partial，資料夾節點停在 running（面板一直轉圈，像還在傳）。
    抽出 `settleRunningNodes`：暫停與重開 app 載入時一致處理（檔案 → partial、其他 → pending）；佇列測試加入檢查。
  - 補 `docs/screenshots/queue.png`：以示範資料在第 2 個檔案完成時自動暫停，呈現已完成／中斷待續傳／等待中的檔案狀態。

- 2026-10-16｜**README 加入功能截圖**
  - `docs/screenshots/`：主畫面、工作面板、衝突對話框（寬 1600px）；裝置序號、裝置名稱、Team ID／bundle ID、個人檔名與本機路徑皆打像素化馬賽克，並放大檢查邊界。
  - 工作面板與衝突對話框以示範資料拍攝；拍攝時透過 UI 驗證 Android → Mac 續傳（47.68MB 接續至 120MB，兩端 MD5 一致）。
  - 新增 `docs/README.md`（截圖說明與打碼規則）。

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
