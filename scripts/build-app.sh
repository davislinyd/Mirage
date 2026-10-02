#!/bin/sh
# 建置 build/Mirage.app。鑰匙圈有 Developer ID Application 或 Apple Development 憑證時用它簽章：簽章身分固定，
# 重新建置後相機與輔助使用權限仍有效。沒有時用 ad-hoc 簽章：每次重新建置，系統都把它當成新的 App，要重新允許。
# MIRAGE_SIGN_IDENTITY 可指定憑證（例如 "Developer ID Application: 名字 (TEAMID)"）。
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product Mirage
app=build/Mirage.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Mirage" "$app/Contents/MacOS/"
cp App/Info.plist "$app/Contents/"
# build 號用建置時間，每次都不同；選單底部看得到，用來確認裝的是新版。要在簽章前改，Info.plist 在簽章範圍內。
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M%S)" "$app/Contents/Info.plist"
identity=${MIRAGE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/"(Developer ID Application|Apple Development): /{print $2; exit}')}
# Hardened Runtime 下要有相機 entitlement 才能用鏡頭。
codesign --force --options runtime --entitlements App/Mirage.entitlements --sign "${identity:--}" "$app"
echo "已建置 ${app}（簽章：${identity:-ad-hoc}）"
