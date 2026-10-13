#!/bin/bash
# Packages dist/Hushtype.app into a compressed, drag-to-install DMG.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Hushtype.app"
[ -d "$APP" ] || "$ROOT/Scripts/build_app.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/Hushtype-$VERSION.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hushtype-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Hushtype" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
[ -n "${HUSHTYPE_SIGN_IDENTITY:-}" ] && codesign --force --timestamp --sign "$HUSHTYPE_SIGN_IDENTITY" "$DMG"
echo "$DMG"
