# 安裝與建置

需求：macOS 14+、**完整的 Xcode**（Swift 6）。只有 Command Line Tools 不行：新版 SDK 的 SwiftUI 以巨集實作 `@State` 等，
巨集外掛只隨 Xcode 提供，否則會出現「plugin for module 'SwiftUIMacros' not found」。`make-app.sh`／`install.sh` 會在
xcode-select 指向 Command Line Tools 時自動改用已安裝的 Xcode；自行執行 `swift build` 時請先
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`（或在指令前加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）。
不需 Java、Gradle。
必要：Homebrew 的 `libmtp`（MTP 裝置存取）與 adb（`android-platform-tools`，已有 Android SDK 可沿用）；`install.sh` 會自動安裝。
選用：Homebrew 的 `libimobiledevice` + `ideviceinstaller`（iPhone 媒體區與 App 文件）、`scrcpy`（Android 鏡像）。
缺少任何一項時，app 內「輔助說明 → 安裝導引」會顯示步驟、官方下載連結與安裝指令。

## 一鍵安裝（建議）

```bash
./tools/install.sh                 # 互動詢問選用相依
./tools/install.sh --yes           # 選用相依全裝、不詢問
./tools/install.sh --no-deps --skip-tests --dest ~/Applications
```

腳本會：檢查 macOS／Xcode 工具鏈（指向 Command Line Tools 時自動改用 Xcode）→ 安裝選用相依 →
`swift test` → `make-app.sh release` → 安裝為 `/Applications/Smartphone File Manager.app`（無權限時改 `~/Applications`）。

## 手動

```bash
./tools/make-app.sh release        # 產物：.build/SmartphoneFileManager.app
```

- 首次開啟若被 Gatekeeper 擋：右鍵 → 打開（ad-hoc 簽章）。
- 螢幕鏡像：`brew install scrcpy`，或在 設定 → 螢幕鏡像 指定路徑。
- adb 來源可在 設定 → ADB 切換（內附／自訂／系統 PATH・Homebrew・Android SDK）。
- iPhone：接上、解鎖、點「信任這部電腦」；未安裝 libimobiledevice 時來源選單會提示。
- 新增/修改 UI 字串後：在 `tools/zh-Hant.json` 補繁中翻譯，執行 `python3 tools/gen-strings.py`（簡中自動產生；不滿意的寫進 `tools/zh-Hans.overrides.json`）。
  擷取全部鍵：`swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <dir>`，
  再以 `--check <keys.json>` 檢查缺漏。
