# 第三方來源與授權聲明（Third-Party Notices）

本專案（Smartphone File Manager）以 MIT 授權釋出，見 [`LICENSE`](LICENSE)。
以下條列本專案引用、移植、內附或執行時呼叫的第三方來源，以及各自的授權與使用方式。

> 維護規則：新增任何相依套件、內附檔案、移植程式碼或參考規格時，同步更新本檔。

## 1. 移植來源

| 來源 | 授權 | 使用方式 |
|---|---|---|
| [wkbin/AdbFileManager](https://github.com/wkbin/AdbFileManager) v3.1.2（Kotlin／Compose）<br>Copyright (c) 2023 Kebin Wang | MIT | 本專案為其 macOS SwiftUI 移植：功能設計、adb 操作流程、介面文字與部分邏輯源自原版。原版 MIT 授權聲明保留於 [`LICENSE`](LICENSE)。 |
| 同上專案的 `tools/clipboard-helper/ClipboardHelper.java` | MIT | `vendor/clipboard-helper.dex.b64` 為其編譯產物（自原版 `src/main/composeResources/files/android/` 取得），於 Android 端執行以寫入剪貼簿。 |

## 2. 內附於 app 的二進位檔

| 項目 | 版本 | 授權 | 說明 |
|---|---|---|---|
| Android Debug Bridge（`vendor/adb`） | 1.0.41（Platform-Tools 36.0.0-13206524） | 原始碼：Apache-2.0（[AOSP `packages/modules/adb`](https://android.googlesource.com/platform/packages/modules/adb/)）<br>官方二進位檔：[Android SDK 授權條款](https://developer.android.com/studio/terms) | ⚠ **開源發佈前待決**：官方二進位檔的再散布受 SDK 授權條款約束。建議擇一：(a) repo 不內附，改由使用者安裝（`brew install --cask android-platform-tools`），app 已支援自動尋找系統 adb；(b) 由 AOSP 原始碼自行建置後內附，依 Apache-2.0 附上授權與 NOTICE。 |

## 3. 連結的函式庫

| 函式庫 | 授權 | 使用方式 |
|---|---|---|
| [libmtp](https://github.com/libmtp/libmtp) 1.1.23 | LGPL-2.1-or-later | MTP 裝置存取（`Sources/CLibMTP` 僅 import 其標頭）。建置與執行皆需 Homebrew 安裝的 `libmtp.dylib`，以**動態弱連結**使用，不內附、不修改；使用者可自行替換函式庫版本，符合 LGPL 動態連結條件。 |
| [libusb](https://github.com/libusb/libusb) 1.0.30 | LGPL-2.1-or-later | libmtp 的相依套件，由 Homebrew 安裝、動態連結，不內附。 |

## 4. 執行時呼叫的外部工具（不內附、不連結）

以獨立子行程執行，由使用者自行安裝（app 內「安裝導引」提供官方連結與安裝指令）。

| 工具 | 授權 | 用途 |
|---|---|---|
| [libimobiledevice](https://libimobiledevice.org)（`afcclient`、`idevice_id`、`ideviceinfo`） | LGPL-2.1-or-later | iPhone 檔案存取（AFC、house_arrest） |
| [ideviceinstaller](https://github.com/libimobiledevice/ideviceinstaller) | GPL-2.0-or-later | 列出 iPhone 上可分享檔案的 App |
| [scrcpy](https://github.com/Genymobile/scrcpy) | Apache-2.0 | Android 螢幕鏡像 |
| [Homebrew](https://brew.sh) | BSD-2-Clause | 安裝導引中建議的套件管理器 |

## 5. 系統框架與資源

| 項目 | 說明 |
|---|---|
| SwiftUI、AppKit、Foundation、UniformTypeIdentifiers | Apple 系統框架，隨 macOS 提供 |
| SF Symbols | 介面圖示，依 [Apple SF Symbols 授權](https://developer.apple.com/sf-symbols/) 於 Apple 平台 app 中使用 |
| ICU（經 Foundation `StringTransform`） | `tools/hant2hans.swift` 繁轉簡使用系統內建 ICU 轉換（[Unicode License](https://www.unicode.org/license.txt)），不內附 |

## 6. 技術參考（規格與文件）

實作時依據的公開規格與文件；未複製其內容。

- USB Implementers Forum，*Media Transfer Protocol v1.1*（MTP 操作碼、物件格式、儲存空間模型）
- [libmtp API 文件](https://libmtp.sourceforge.net/)（`LIBMTP_*` 函式語意）
- [libimobiledevice 文件](https://libimobiledevice.org)（AFC／house_arrest 服務；實測行為記錄於 `Sources/SFMCore/Sources/IPhoneFileSource.swift`）
- [Android 開源專案：儲存空間](https://source.android.com/docs/core/storage)（`/sdcard`、`/storage/emulated`、vold 掛載結構）
- [Android Debug Bridge 文件](https://developer.android.com/tools/adb)
