# 背景與設計取捨

原版是 Kotlin + Compose Desktop 的跨平台 app（JVM，約 1.3 萬行），只管 Android。
這版目標是原生 SwiftUI、零 JVM，並擴充為 Mac／Android／iPhone 任意互傳，因此改名 Smartphone File Manager。

| 取捨 | 選擇 | 理由 |
|---|---|---|
| 專案格式 | SwiftPM + `make-app.sh` | 以檔案系統為準，新增檔案不用改 pbxproj；Xcode 可直接開 `Package.swift` |
| 分層 | L1 `SFMCore`（無 UI）＋ L4 App | 解析器、shell 跳脫、子行程取消等最容易錯的部分可單元測試 |
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
| 來源抽象 | `FileSource` 協定 + Mac／Android／iPhone 三實作 | 窗格、剪貼簿、拖放、編輯器只依賴協定；新增來源（例如 MTP）只需新實作 |
| 跨來源傳輸 | 只用 `download`／`upload` 兩個原語，`FileTransfer` 決定原生或經 Mac 中繼 | 來源之間互不認識，N 種來源不需 N² 條路徑 |
| 剪下的安全性 | 複製成功後才刪來源；取消只清除本次新建的目的項目；同來源 mv 絕不清除 | 任何時點中斷都不會兩頭落空 |
| 同名衝突 | 自動改名（`a 2.txt`），不覆寫 | 免對話框、絕不覆蓋既有資料（與 Finder 的「保留兩者」相同） |
| iPhone | libimobiledevice `afcclient`（每操作一個行程） | macOS 無公開 API；afcclient 錯誤時結束碼仍為 0、rm 不遞迴、無 copy、互動模式讀 EOF 不結束——皆已在實作中處理並記錄 |
| Mac 刪除 | 移到垃圾桶 | 可復原 |
| 等待子行程 | `terminationHandler` + semaphore，不用 `waitUntilExit()` | 後者輪詢目前執行緒的 run loop，實測在測試宿主中永遠等不到而卡死 |
| 網路來源識別 | `SourceID.Kind.network`＋帳號 id，協定在帳號設定 | 新增協定不動 Kind 與各處 switch；書籤、同步、佇列以 SourceID 運作，免改 |
| 協定 → 實作 | 只在 `NetworkSourceFactory` | App 層只拿到 `any FileSource`，不認識各協定型別（減法彈性：拿掉一個協定只改工廠與編輯器） |
| FTP／FTPS／SFTP | lftp 子行程（每操作一個行程），不自寫協定 | 一個工具涵蓋主動／被動、FTPS explicit／implicit、SFTP 密碼／金鑰、續傳與檔名編碼；自寫 FTP 資料通道與 TLS session reuse 成本高。代價：每次操作重新登入（約 0.1～1 秒） |
| FTPS 的 TLS 版本 | 以 `OPENSSL_CONF` 限制 lftp 為 TLS 1.2，上傳後驗證大小 | 實測 lftp 4.9.3＋OpenSSL 3 在 TLS 1.3 資料通道上傳會截斷檔尾且回報成功（Python ftplib TLS 1.3 正常 → lftp 端問題）；Homebrew lftp 連結 OpenSSL，`ssl:priority` 無效 |
| lftp 的重試 | 一律依帳號選項覆寫 `net:max-retries`、`net:timeout` | lftp 預設重試 1000 次、逾時 5 分鐘，連不上時窗格會像當掉 |
| 密碼傳遞 | `open --env-password`（環境變數 `LFTP_PASSWORD`） | 不出現在行程參數（`ps`）與 log |
| 額外 lftp 設定 | 只接受 `set …` 行 | 自由文字若可為任意 lftp 指令（`!shell`）風險過高 |
| SFTP 主機金鑰 | app 專用 known_hosts、首次自動記住（accept-new） | 不動 `~/.ssh/known_hosts`；變更時拒絕連線，選項視窗可「忘記」。ssh 會把 UserKnownHostsFile 的值以空白切開，路徑需再包雙引號 |
| WebDAV | 移植 nas_webdav 的用戶端（改 async、加進度與 Range 續傳） | 同一作者已驗證的 multistatus 解析、憑證釘選、部分寫入探測；探測只用隱藏探測檔，不拿真檔案試 |
| 明文連線 | 允許（http、純 FTP），帳號清單與窗格標示「未加密」 | 區網 NAS／路由器常只有純 FTP；由使用者決定 |
| pCloud 登入 | 預設 Email＋密碼（`getdigest`＋`passworddigest` 換 auth token，支援兩步驟驗證）；OAuth2 為選用 | OAuth 需註冊 App 且要等 pCloud 核准，太耗時 → 改為帳號密碼直接登入：密碼以一次性 digest 雜湊送出、不存，只存 token，登出時呼叫 `logout` 作廢；地區先試使用者選的區、失敗再試另一區。OAuth（選用）：歐洲帳號必須打 `eapi.pcloud.com`——以回呼的 `hostname`／`locationid` 決定地區並換 token，hostname 只接受兩個官方 host（不把 client secret 送到別處） |
| pCloud 上傳續傳 | 大於一段（32 MB）的檔案走上傳工作階段（`upload_create`／`upload_write`／`upload_info`／`upload_save`），每段一個請求；工作階段 ID 記在 Application Support 的 `pcloud-uploads.json` | 單一 `uploadfile` 傳十幾 GB 時，傳完等伺服器處理會逾時、中途斷線就整份重來（實際發生：12～34 GB 的檔案大多失敗）。這組 API 官方文件未列，但官方 Swift SDK 使用（參數依 SDK）。已寫入多少一律以伺服器 `upload_info` 為準；本機檔大小或修改時間變了就建新的工作階段。存檔前目的端看不到檔案，所以衝突對話框的「續傳」仍不適用（`resumable == false`） |
| 暫時性錯誤重試 | 執行器層統一處理：單檔傳輸遇到斷線／逾時／EIO／ENXIO 或 Mac 端外接磁碟被卸載時，依序等 5、10、20、30、60、60、120、120、300、300 秒再呼叫一次 | 重試＝再呼叫一次單檔傳輸，各來源的續傳從已傳的部分接著做，所以不必每個來源各寫一套；帳密錯誤、檔案不存在等等待也不會好轉的錯誤照常失敗。各協定自己的短重試（WebDAV、lftp）仍保留，處理瞬間的小斷線 |
| 帳號選項 | 每欄 Optional＝沿用全域預設，`resolved(defaults:)` 產生具體值 | FileSource 不讀 UserDefaults，core 可測試；全域預設與帳號選項共用同一個表單 |
| 工作進度與預估時間 | 資料夾執行到才展開；速率以 1 秒視窗＋指數移動平均 | 不像其他檔案管理器先掃描整棵樹才開始（大量小檔或慢速裝置要等很久）：第一個檔案立刻傳，目前檔案的百分比與剩餘時間馬上有；整體總量隨掃描逐步增加，掃描中預估標為「至少」。速率只算實際傳輸的增量，略過的檔案不灌高速率。同步需比對兩邊，仍事先展開 |
| 並行傳輸 | 網路帳號選項「同時傳輸數」N（預設 1）：N ≥ 2 時 1 個**主執行器**（大檔）＋ N−1 個**子執行器**（小檔），佇列依大小分流；主執行器一律多連線、子執行器單一連線（連線數由執行器決定，不看大小） | 大檔吃頻寬、小檔吃延遲：小檔適合多檔並行，大檔適合單檔多連線。分開名額讓大檔不擋小檔、小檔不搶大檔頻寬。名額由整個工作共用（巢狀資料夾不超過上限），資料夾遍歷不佔名額不會死結；大檔在背景等主執行器，不擋住後面的小檔。N = 1 時唯一的執行器即主執行器，所以每個下載都多連線（小於兩個區塊的檔案切不開，實際仍是一個請求）。取涉及的非 Mac 來源中最小上限：手機（adb／AFC／MTP）固定 1 |
| 大檔多連線下載 | WebDAV／pCloud：8 MiB 區塊、多連線 Range，完成的區塊記在隱藏狀態檔；FTP／SFTP：lftp `pget -n`，進度讀 pget 狀態檔 | 分段下載的檔案大小一開始就接近完整，不能用大小判斷進度或完成度：**狀態檔存在＝未完成**，續傳一律沿用分段方式；從單一連線的部分檔接續時前段視為完成。上傳不分段：各協定沒有可靠的多連線寫同一檔方式。停止時 Mac 端一併清除狀態檔 |
| 大檔下載落地方式 | WebDAV／pCloud 超過一個區塊（8 MB）的檔案一律分區塊（`SegmentedDownload`），連線數 1 也是；區塊遇暫時性錯誤就地重試 1、3 秒 | URLSession 的單一 GET 下載到暫存檔、完成才搬過去，斷線時已下載的部分全部遺失，重試又從原處開始——十幾 GB 的檔案幾乎傳不完。分區塊每完成一塊就寫入並記錄，子執行器（單一連線）被主執行器接手時也能直接以多連線接續 |
| 執行器進度顯示 | 佇列記錄每個傳輸中檔案的執行器（`fileLanes`）與它自己的速率（`fileRates`）；子執行器帶編號 `ExecutorLane.sub(n)` | 只顯示主執行器時看不出子執行器在做什麼；改為每個執行器一條進度、固定顏色（主藍色，子依編號輪流取色），自訂進度條因為系統 ProgressView 在 macOS 不一定套用 tint |
| 主／子執行器分派 | 整個工作共用一個分派器（`TransferDispatcher` actor）：遍歷是生產者、1 主＋N−1 子是工作者 | 依資料夾逐層取名額無法做到「子執行器沒小檔時取大檔」與「主執行器接手子執行器的大檔」——這需要看得到全工作的排隊與執行狀況。接手只限「下載到 Mac」：子執行器停下（存為 partial）後主執行器以多連線續傳；上傳一律單一連線、pCloud 上傳不能續傳，接手反而變慢。小檔佇列上限＝子執行器數，資料夾不會被一口氣展開。只用於雲端（網路帳號），手機與 Mac 維持逐檔 |
