#!/bin/bash
# 在另一台 Mac 上從原始碼安裝 Smartphone File Manager。
#
# 做的事（依序）：
#   1. 檢查 macOS 版本（14+）與 Swift toolchain（Xcode 或 Command Line Tools）
#   2. 選用相依（Homebrew）：libimobiledevice + ideviceinstaller（iPhone）、scrcpy（螢幕鏡像）
#   3. 跑核心層單元測試（可略過）
#   4. 以 release 組出 .app，安裝到 /Applications（無寫入權限時改 ~/Applications）
#
# 用法：
#   ./tools/install.sh                 互動詢問選用相依
#   ./tools/install.sh --yes           選用相依全部安裝、不詢問
#   ./tools/install.sh --no-deps       不安裝任何選用相依
#   ./tools/install.sh --skip-tests    略過單元測試
#   ./tools/install.sh --dest DIR      指定安裝資料夾
#
# Android 不需要額外安裝：app 內附 adb（亦可在設定改用 Android SDK／Homebrew 的 adb）。
set -euo pipefail
cd "$(dirname "$0")/.."

ASSUME_YES=0
NO_DEPS=0
SKIP_TESTS=0
DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1 ;;
        --no-deps) NO_DEPS=1 ;;
        --skip-tests) SKIP_TESTS=1 ;;
        --dest) DEST="$2"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知參數：$1" >&2; exit 2 ;;
    esac
    shift
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告：\033[0m%s\n' "$*" >&2; }
die()  { printf '\033[1;31m錯誤：\033[0m%s\n' "$*" >&2; exit 1; }

ask() {   # ask "問題" → 0=是 1=否
    [ "$NO_DEPS" = 1 ] && return 1
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "$1 [Y/n] " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# ── 1. 系統需求 ─────────────────────────────────────────────
info "檢查系統需求"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "需要 macOS 14 以上（目前 $(sw_vers -productVersion)）"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    warn "找不到 Swift toolchain，將開啟 Command Line Tools 安裝視窗；安裝完成後請重新執行本腳本"
    xcode-select --install || true
    exit 1
fi
swift_version=$(swift --version 2>/dev/null | head -1)
info "Swift：$swift_version"
# Package.swift 需要 swift-tools-version 6.0
echo "$swift_version" | grep -Eq 'Swift version (6|[7-9])\.' || die "需要 Swift 6 以上（請更新 Xcode 或 Command Line Tools）"

# ── 2. 選用相依 ─────────────────────────────────────────────
if command -v brew >/dev/null 2>&1; then
    if ! command -v afcclient >/dev/null 2>&1 || ! command -v ideviceinstaller >/dev/null 2>&1; then
        if ask "安裝 libimobiledevice + ideviceinstaller（存取 iPhone 媒體區與 App 文件需要）？"; then
            brew install libimobiledevice ideviceinstaller
        fi
    else
        info "libimobiledevice／ideviceinstaller 已安裝"
    fi
    if ! command -v scrcpy >/dev/null 2>&1; then
        if ask "安裝 scrcpy（Android 螢幕鏡像需要）？"; then
            brew install scrcpy
        fi
    else
        info "scrcpy 已安裝"
    fi
else
    warn "未安裝 Homebrew：iPhone 存取（libimobiledevice）與螢幕鏡像（scrcpy）需自行安裝。https://brew.sh"
fi

# ── 3. 測試 ────────────────────────────────────────────────
if [ "$SKIP_TESTS" = 0 ]; then
    info "執行單元測試"
    swift test 2>&1 | tail -3
fi

# ── 4. 組 app 並安裝 ────────────────────────────────────────
info "建置 release 版"
./tools/make-app.sh release
APP=".build/SmartphoneFileManager.app"

if [ -z "$DEST" ]; then
    if [ -w /Applications ]; then DEST="/Applications"; else DEST="$HOME/Applications"; fi
fi
mkdir -p "$DEST"
TARGET="$DEST/Smartphone File Manager.app"

# 正在執行的舊版先結束，否則複製會失敗或執行到舊檔
pkill -f "Smartphone File Manager.app/Contents/MacOS/" 2>/dev/null || true
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"
# 本機自建的 app 沒有下載隔離屬性，保險起見仍清除（例如整個 repo 是從網路下載的 zip）
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

info "已安裝：$TARGET"
cat <<EOF

完成。第一次使用：
  • Android：手機開啟 USB 偵錯並接上，在手機上允許偵錯
  • iPhone：接上、解鎖並點「信任這部電腦」
  • macOS 若詢問「下載項目／文件」資料夾存取權，請允許（或在 設定 → 隱私權與安全性 → 檔案與資料夾）

啟動：open "$TARGET"
EOF
