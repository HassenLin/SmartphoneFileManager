# 安裝與建置

需求：macOS 14+、Swift 6 toolchain（Xcode 或 Command Line Tools）。不需 Java、Gradle。
選用：Homebrew 的 `libimobiledevice`（iPhone）、`scrcpy`（Android 鏡像）。

## 一鍵安裝（建議）

```bash
./tools/install.sh                 # 互動詢問選用相依
./tools/install.sh --yes           # 選用相依全裝、不詢問
./tools/install.sh --no-deps --skip-tests --dest ~/Applications
```

腳本會：檢查 macOS／Swift 版本（缺 toolchain 時開啟 Command Line Tools 安裝）→ 安裝選用相依 →
`swift test` → `make-app.sh release` → 安裝為 `/Applications/Smartphone File Manager.app`（無權限時改 `~/Applications`）。

## 手動

```bash
./tools/make-app.sh release        # 產物：.build/SmartphoneFileManager.app
```

- 首次開啟若被 Gatekeeper 擋：右鍵 → 打開（ad-hoc 簽章）。
- 螢幕鏡像：`brew install scrcpy`，或在 設定 → 螢幕鏡像 指定路徑。
- adb 來源可在 設定 → ADB 切換（內附／自訂／系統 PATH・Homebrew・Android SDK）。
- iPhone：接上、解鎖、點「信任這部電腦」；未安裝 libimobiledevice 時來源選單會提示。
- 新增/修改 UI 字串後：在 `tools/zh-Hant.json` 補翻譯，執行 `python3 tools/gen-strings.py`。
  擷取全部鍵：`swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <dir>`，
  再以 `--check <keys.json>` 檢查缺漏。
