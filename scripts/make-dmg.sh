#!/bin/zsh
# Builds a universal Grafit.app and packs it into build/Grafit-<version>.dmg
# (drag-to-Applications layout). Usage: VERSION=0.1.0 scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/bundle.sh --universal

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Grafit.app/Contents/Info.plist)
DMG="build/Grafit-${VERSION}.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/grafit-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

cp -R build/Grafit.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Grafit ${VERSION}" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo "Created $DMG"
shasum -a 256 "$DMG"
