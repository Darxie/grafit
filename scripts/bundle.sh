#!/bin/zsh
# Builds a release binary and wraps it into build/GitExMac.app.
# Usage: scripts/bundle.sh [--install]   (--install copies the app to /Applications)
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

APP=build/GitExMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GitExMac "$APP/Contents/MacOS/GitExMac"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Git Extensions</string>
    <key>CFBundleDisplayName</key><string>Git Extensions</string>
    <key>CFBundleIdentifier</key><string>local.gitexmac</string>
    <key>CFBundleExecutable</key><string>GitExMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/GitExMac.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/GitExMac.app"
fi
