#!/bin/bash
# 編譯 TokenMeter.app 並打包成 DMG（在 macOS 上執行，GitHub Actions 也用這支）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
OUT="build"
APP="$OUT/TokenMeter.app"
DMG="$OUT/TokenMeter-$VERSION.dmg"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ 編譯（Apple Silicon + Intel）"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" \
    Sources/TokenMeter.swift -o "$OUT/TokenMeter-$arch"
done
lipo -create "$OUT/TokenMeter-arm64" "$OUT/TokenMeter-x86_64" -output "$APP/Contents/MacOS/TokenMeter"
rm "$OUT"/TokenMeter-arm64 "$OUT"/TokenMeter-x86_64

cp Sources/dashboard.html "$APP/Contents/Resources/dashboard.html"

echo "→ 產生圖示"
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TokenMeter</string>
  <key>CFBundleDisplayName</key><string>TokenMeter</string>
  <key>CFBundleIdentifier</key><string>com.boyce.tokenmeter</string>
  <key>CFBundleExecutable</key><string>TokenMeter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>TokenMeter · Claude Token 用量監控</string>
</dict>
</plist>
PLIST

echo "→ 簽章（ad-hoc）"
codesign --force --deep --sign - "$APP"

echo "→ 打包 DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/第一次打開請看.txt" <<'TXT'
安裝
1. 把 TokenMeter 拖進右邊的 Applications（應用程式）資料夾。
2. 打開「應用程式」，點兩下 TokenMeter。

如果出現「無法驗證開發者」或「Apple 無法檢查是否含有惡意軟體」：
1. 按「完成」或「好」關閉視窗。
2. 打開「系統設定」→「隱私權與安全性」，往下捲。
3. 找到「已阻擋 TokenMeter」，按「仍要打開」，輸入 Mac 密碼。
只需要做一次。

打開後
- 右上角系統列會出現儀表圖示。
- 第一次查詢額度時，macOS 會問是否允許存取鑰匙圈，請按「永遠允許」。
- TokenMeter 預設開機自動啟動，可以在面板右下角的「開機啟動」切換。
TXT
hdiutil create -volname "TokenMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ 完成：$DMG"
