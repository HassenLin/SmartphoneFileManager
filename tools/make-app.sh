#!/bin/bash
# 把 SwiftPM 產出的執行檔組成 .app bundle。
#
# 專案以 SwiftPM 管理（不手寫
# .xcodeproj），缺的只有 app bundle 外殼，這支腳本補上：
#   - Info.plist（含拖曳用的自訂 UTType 宣告、語系清單）
#   - 內附 adb（本機 vendor/adb 或系統 adb）與剪貼簿 helper（→ Contents/Resources/bin/）
#   - 多語系字串（Localization/*.lproj → Contents/Resources/）
#   - 圖示（tools/AppIcon.icns）
#   - 簽章：優先用鑰匙圈裡有效的 Apple Development 憑證（固定身分），找不到才 ad-hoc
#
# 用法：./tools/make-app.sh [debug|release]   產物：.build/SmartphoneFileManager.app
set -euo pipefail
cd "$(dirname "$0")/.."
# 需要完整 Xcode 的工具鏈（SwiftUI 巨集外掛），見 xcode-env.sh
source tools/xcode-env.sh

CONFIG="${1:-debug}"
APP_NAME="SmartphoneFileManager"
DISPLAY_NAME="Smartphone File Manager"
BUNDLE_ID="idv.hassen.smartphonefilemanager.mac"
VERSION="1.0.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP=".build/${APP_NAME}.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# 內附 adb 與剪貼簿 helper dex。
# 放在 Resources/bin 而非 MacOS/：它們是資源，不是這個 app 的主程式；
# AdbLocator.bundledPath() 與 ClipboardService.loadHelper() 從這裡找。
#
# adb 是 Google SDK Platform-Tools 的二進位檔，其再散布受 Android SDK 授權條款約束，
# 所以 repo 不收錄（vendor/adb 已列入 .gitignore）。組 app 時依序取：
#   1. 本機放置的 vendor/adb　2. 系統 adb（Homebrew android-platform-tools、Android SDK、PATH）
# 都沒有就不內附——app 執行時會自動改用系統 adb（AdbLocator 的退路）。
ADB_SRC=""
if [ -x vendor/adb ]; then
    ADB_SRC="vendor/adb"
else
    for candidate in "$(command -v adb 2>/dev/null || true)" /opt/homebrew/bin/adb /usr/local/bin/adb \
                     "${ANDROID_HOME:-}/platform-tools/adb" "$HOME/Library/Android/sdk/platform-tools/adb"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then ADB_SRC="$candidate"; break; fi
    done
fi
if [ -n "$ADB_SRC" ]; then
    cp -L "$ADB_SRC" "$APP/Contents/Resources/bin/adb"   # -L：Homebrew 的 adb 是符號連結
    chmod 755 "$APP/Contents/Resources/bin/adb"
    echo "內附 adb：$ADB_SRC"
else
    echo "警告：找不到 adb，未內附（brew install --cask android-platform-tools）" >&2
fi
cp vendor/clipboard-helper.dex.b64 "$APP/Contents/Resources/bin/"

# 多語系：SwiftUI 的 Text("…") 與 String(localized:) 都查 Bundle.main，
# 所以 .lproj 要放在 app bundle 本身，而不是 SwiftPM 的資源 bundle。
cp -R Localization/*.lproj "$APP/Contents/Resources/"

if [ -f tools/AppIcon.icns ]; then
    cp tools/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "警告：找不到 tools/AppIcon.icns，這次組出來的 app 沒有圖示" >&2
    echo "      產生方式：swift tools/make-icon.swift" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hant</string><string>zh-Hans</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- 自用工具、不上架，App Sandbox 關閉：要執行 adb／scrcpy 子行程、
         讀寫使用者任意選擇的資料夾，兩者在 sandbox 下都會被擋。 -->
    <!-- 窗格之間拖曳／剪貼簿用的私有型別（攜帶來源與項目清單） -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>idv.hassen.smartphonefilemanager.remote-file</string>
            <key>UTTypeDescription</key><string>Smartphone File Manager item reference</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# 簽章身分：鑰匙圈項目（網路帳號密碼、pCloud token）的存取權限綁在 app 的簽章上。
# ad-hoc 簽章每次 build 的 cdhash 都不同，macOS 視為另一個 app，每次重 build 都要重新「允許」；
# 用固定的 Apple Development 憑證簽，權限綁在「bundle id＋憑證」上，同意一次就一直有效。
#   SFM_SIGN_IDENTITY  指定身分（SHA-1 或名稱；"-"＝強制 ad-hoc）
#   SFM_SIGN_TEAM      未指定身分時優先挑這個 team 的憑證（預設 34ZXLE998M），沒有就挑任一有效的
# 不上架、不公證；真的要散佈時再改 Developer ID。
pick_identity() {
    # find-identity -v 仍會列出已撤銷的憑證（標 CSSMERR_TP_CERT_REVOKED），要濾掉
    local valid
    valid="$(security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development:' | grep -v CSSMERR || true)"
    { grep "(${SFM_SIGN_TEAM:-34ZXLE998M})\"" <<<"$valid" || true; echo "$valid"; } | awk 'NF && !found { print $2; found = 1 }'   # 不用 exit：提早關管線會 SIGPIPE，pipefail 下整支腳本中止
}
IDENTITY="${SFM_SIGN_IDENTITY:-$(pick_identity)}"
IDENTITY="${IDENTITY:--}"
# 不用 --deep：內附的 adb 已由 Google 簽章，重簽反而破壞它。--timestamp=none：離線也能簽。
if [ "$IDENTITY" != "-" ] && codesign --force --timestamp=none --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "簽章：$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "簽章：ad-hoc（找不到可用的 Apple Development 憑證；重新 build 後鑰匙圈會再詢問權限）"
fi

echo "已組出 $APP"
