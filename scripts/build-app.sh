#!/bin/sh
# Builds build/Nudge.app (the menu bar app). Notifications need a real bundle with
# an identifier, so the bare SwiftPM executable isn't enough.
# With --install, also replaces ~/Applications/Nudge.app and relaunches it.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product NudgeBar
app=build/Nudge.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/NudgeBar "$app/Contents/MacOS/Nudge"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.jgpasch.nudge</string>
    <key>CFBundleName</key><string>Nudge</string>
    <key>CFBundleExecutable</key><string>Nudge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"

if [ "${1:-}" = "--install" ]; then
    dest="$HOME/Applications/Nudge.app"
    pkill -x Nudge || true
    mkdir -p "$HOME/Applications"
    rm -rf "$dest"
    cp -R "$app" "$dest"
    open "$dest"
    echo "Installed $dest"
fi
