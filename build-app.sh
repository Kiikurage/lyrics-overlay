#!/bin/bash
# release ビルドして LyricsOverlay.app を組み立てる。
set -euo pipefail
cd "$(dirname "$0")"

APP="LyricsOverlay.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LyricsOverlay "$APP/Contents/MacOS/LyricsOverlay"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>LyricsOverlay</string>
    <key>CFBundleDisplayName</key>     <string>Lyrics Overlay</string>
    <key>CFBundleIdentifier</key>      <string>local.lyrics-overlay</string>
    <key>CFBundleExecutable</key>      <string>LyricsOverlay</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <!-- Dock とメニューバーに出さない、常駐アクセサリアプリ -->
    <key>LSUIElement</key>             <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>再生中の曲と再生位置を取得するために Spotify を操作します。</string>
</dict>
</plist>
PLIST

# TCC の許可をバンドル単位で安定して記憶させるため ad-hoc 署名する。
codesign --force --sign - "$APP"

echo "built: $PWD/$APP"
