#!/bin/zsh
# Builds a release binary and wraps it into build/Grafit.app.
# Usage: scripts/bundle.sh [--universal] [--install]
#   --universal  build for Apple Silicon and Intel (arm64 + x86_64)
#   --install    copy Grafit.app to /Applications
# VERSION=1.2.3 overrides the version (default: latest vX.Y.Z tag, else 0.1.0).
set -euo pipefail

cd "$(dirname "$0")/.."

UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --install) INSTALL=true ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [[ -z "${VERSION:-}" ]]; then
    VERSION=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)
    VERSION=${VERSION:-0.1.0}
fi
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

BUILD_ARGS=(-c release)
$UNIVERSAL && BUILD_ARGS+=(--arch arm64 --arch x86_64)
swift build "${BUILD_ARGS[@]}"
BINARY="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/Grafit"

APP=build/Grafit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Grafit"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
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

# Ad-hoc signature: enough to run locally; not a Developer ID signature (see README).
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP (version $VERSION, build $BUILD_NUMBER$($UNIVERSAL && echo ', universal'))"

if $INSTALL; then
    rm -rf "/Applications/Grafit.app"
    cp -R "$APP" /Applications/
    # Remove the app from before the rename (settings are migrated on first launch).
    rm -rf "/Applications/GitExMac.app"
    echo "Installed to /Applications/Grafit.app"
fi
