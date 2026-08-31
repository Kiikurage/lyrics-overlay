#!/bin/bash
# release ビルドして LyricsOverlay.app を組み立てる。
# -r / --run を付けると、組み立て後に起動中のアプリを終了して開き直す。
set -euo pipefail
cd "$(dirname "$0")"

APP="LyricsOverlay.app"
RESTART=0
[[ "${1:-}" == "-r" || "${1:-}" == "--run" ]] && RESTART=1
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
    <key>LSMinimumSystemVersion</key>  <string>14.2</string>
    <!-- Dock とメニューバーに出さない、常駐アクセサリアプリ -->
    <key>LSUIElement</key>             <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>再生中の曲と再生位置を取得するために Spotify を操作します。</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>再生中の音に合わせた表示を行うために Spotify の音声を解析します。</string>
</dict>
</plist>
PLIST

# 署名する。
#
# 自己署名証明書があればそれを使う。ad-hoc 署名にはアプリを識別する情報が無く、
# macOS はバイナリのハッシュで判別するので、再ビルドのたびに別のアプリと
# みなされて許可を取り直すことになる。証明書があれば「バンドル ID + 証明書」で
# 判定されるため、中身が変わっても許可が維持される。
# 証明書は scripts/create-signing-cert.sh で作る(Gatekeeper の警告は消えない)。
IDENTITY="LyricsOverlay Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
    echo "signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "signed with: ad-hoc (再ビルドのたびに許可を求められます)"
fi

echo "built: $PWD/$APP"

if [[ $RESTART == 1 ]]; then
    # 起動していなければ pkill は 1 を返すが、それは正常なので握りつぶす。
    pkill -x LyricsOverlay || true
    # 終了しきる前に open すると -600(procNotFound)で失敗するので待つ。
    for _ in $(seq 20); do
        pgrep -x LyricsOverlay >/dev/null || break
        sleep 0.1
    done
    open "$APP"
    echo "restarted: $APP"
fi
