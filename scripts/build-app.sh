#!/bin/sh
# 建置 build/Mirage.app。預設 ad-hoc 簽章：每次重新建置，系統都把它當成新的 App，要重新允許輔助使用。
# 設定 MIRAGE_SIGN_IDENTITY（例如 "Developer ID Application: 名字 (TEAMID)"）改用憑證簽章，重新建置後權限仍有效。
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product Mirage
app=build/Mirage.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Mirage" "$app/Contents/MacOS/"
cp App/Info.plist "$app/Contents/"
# Hardened Runtime 下要有相機 entitlement 才能用鏡頭。
codesign --force --options runtime --entitlements App/Mirage.entitlements --sign "${MIRAGE_SIGN_IDENTITY:--}" "$app"
echo "已建置 $app"
