#!/bin/bash
# 把 SwiftPM 產出的執行檔組成 .app bundle。
#
# 專案以 SwiftPM 管理（不手寫
# .xcodeproj），缺的只有 app bundle 外殼，這支腳本補上：
#   - Info.plist（含拖曳用的自訂 UTType 宣告、語系清單）
#   - 內附 adb 與剪貼簿 helper（vendor/ → Contents/Resources/bin/）
#   - 多語系字串（Localization/*.lproj → Contents/Resources/）
#   - 圖示（tools/AppIcon.icns）
#   - ad-hoc 簽章
#
# 用法：./tools/make-app.sh [debug|release]   產物：.build/SmartphoneFileManager.app
set -euo pipefail
cd "$(dirname "$0")/.."

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

# 內附 adb（Google platform-tools，universal binary）與剪貼簿 helper dex。
# 放在 Resources/bin 而非 MacOS/：它們是資源，不是這個 app 的主程式；
# AdbLocator.bundledPath() 與 ClipboardService.loadHelper() 從這裡找。
cp vendor/adb "$APP/Contents/Resources/bin/adb"
chmod 755 "$APP/Contents/Resources/bin/adb"
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

# 本機自簽（ad-hoc）。不上架，Developer ID 等真的要散佈時再說。
# 不用 --deep：內附的 adb 已由 Google 簽章，重簽反而破壞它。
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "已組出 $APP"
