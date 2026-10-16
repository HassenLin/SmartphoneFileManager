# 安裝與建置

需求：macOS 14+、Xcode（Swift 6 toolchain）。不需 Java、Gradle、Homebrew（scrcpy 鏡像除外）。

```bash
./tools/make-app.sh            # 產物：.build/AdbFileManagerMac.app
cp -R .build/AdbFileManagerMac.app /Applications/   # 選用
```

- 首次開啟若被 Gatekeeper 擋：右鍵 → 打開（ad-hoc 簽章）。
- 螢幕鏡像：`brew install scrcpy`，或在 設定 → 螢幕鏡像 指定路徑。
- adb 來源可在 設定 → ADB 切換（內附／自訂／系統 PATH・Homebrew・Android SDK）。
- 新增/修改 UI 字串後：在 `tools/zh-Hant.json` 補翻譯，執行 `python3 tools/gen-strings.py`。
  擷取全部鍵：`swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <dir>`，
  再以 `--check <keys.json>` 檢查缺漏。
