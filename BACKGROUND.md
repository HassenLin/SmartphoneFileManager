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
| pCloud 上傳續傳 | 不支援（整份重傳） | `uploadfile` 不能指定位置；可日後改 upload_create／upload_write |
| 帳號選項 | 每欄 Optional＝沿用全域預設，`resolved(defaults:)` 產生具體值 | FileSource 不讀 UserDefaults，core 可測試；全域預設與帳號選項共用同一個表單 |
