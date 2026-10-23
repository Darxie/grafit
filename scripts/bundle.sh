#!/bin/zsh
# Builds a release binary and wraps it into build/Grafit.app.
# Usage: scripts/bundle.sh [--install]   (--install copies Grafit.app to /Applications)
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

APP=build/Grafit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Grafit "$APP/Contents/MacOS/Grafit"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Grafit</string>
    <key>CFBundleDisplayName</key><string>Grafit</string>
    <key>CFBundleIdentifier</key><string>cz.feldis.grafit</string>
    <key>CFBundleExecutable</key><string>Grafit</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Grafit.app"
    cp -R "$APP" /Applications/
    # Remove the app from before the rename (settings are migrated on first launch).
    rm -rf "/Applications/GitExMac.app"
    echo "Installed to /Applications/Grafit.app"
fi
