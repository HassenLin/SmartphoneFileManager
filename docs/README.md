# docs

專案文件資源。

## screenshots/

README 使用的 app 截圖（寬 1600px PNG）。

| 檔案 | 內容 |
|---|---|
| `main.png` | 主畫面：左窗格 iPhone App 文件（Finder「檔案」分頁同源）、右窗格 Android `/sdcard` |
| `tasks.png` | 工作面板：Android → Mac 拷貝進行中（展開到檔案的進度）、同裝置第二個工作排隊中 |
| `queue.png` | 工作佇列：兩個已暫停（其一展開：2 個已完成、1 個中斷待續傳、3 個等待中）、一個已完成 |
| `conflict.png` | 衝突對話框：目的已有較小的同名檔，提供續傳（預設）／覆寫／保留兩者／略過 |
| `sync.png` | 同步視窗：Mac ↔ Mac 同步專案（左 → 右），通用選項＋rsync 專用選項（檢查碼、延伸屬性） |
| `bookmarks.png` | 書籤選單：資料夾書籤兩個、同步專案一個；底部工作面板為剛完成的同步 |

`tasks.png`、`queue.png`、`conflict.png` 以示範資料（手機 `/sdcard/Download/SFM-Demo`、Mac 暫存資料夾）拍攝，拍完已刪除示範資料並還原窗格設定。

### 截圖規則（開源專案）

- 截圖前檢查畫面上的敏感資料，一律打**像素化馬賽克**再放入 repo：
  裝置序號（adb serial、MTP 序號、iPhone UDID）、含個人姓名的裝置名稱、開發者 Team ID／bundle ID、個人檔名與路徑。
- 打完馬賽克後放大檢查邊界，確認沒有殘留字元（實例：序號左側曾露出 2 個字元）。
- 以視窗截圖（`screencapture -o -l <windowID>`）避免拍到其他視窗。

## 更動紀錄

- 2026-10-16：加入 `sync.png`、`bookmarks.png`。以示範資料夾 `/Users/Shared/SFM-Demo`（假照片檔）與示範書籤拍攝，
  畫面上沒有裝置、帳號或個人路徑，不需打碼；拍完刪除示範資料並還原 app 設定與書籤。
  - 拍攝時透過 UI 實際執行同步，發現 openrsync `--extended-attributes` 會逐一列出 `._` AppleDouble 項目、使完成提示的檔案數偏高，已修正統計。

- 2026-10-16：建立；加入 `screenshots/main.png`、`tasks.png`、`conflict.png`；補 `queue.png`。
