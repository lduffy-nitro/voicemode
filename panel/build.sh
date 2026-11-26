#!/bin/bash
# Build VoicePanel.app into ./build
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --package-path app
APP=build/VoicePanel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "app/.build/release/VoicePanel" "$APP/Contents/MacOS/VoicePanel"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.voice-panel</string>
  <key>CFBundleName</key><string>VoicePanel</string>
  <key>CFBundleExecutable</key><string>VoicePanel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Voice Panel listens so you can talk to Claude.</string>
</dict></plist>
PLIST
# Sign with a stable local identity so macOS keeps mic / screen permissions across rebuilds
# (ad-hoc signatures change every build, which makes TCC forget the grant).
ID="Voice Panel Local Signing"
if security find-identity -p codesigning | grep -q "\"$ID\""; then
  codesign --force --sign "$ID" "$APP"
else
  echo "note: '$ID' identity not found; ad-hoc signing (permissions reset on rebuild)"
  codesign --force --sign - "$APP"
fi
echo "built $APP"
