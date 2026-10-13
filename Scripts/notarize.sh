#!/bin/bash
# Notarizes and staples the DMG. Requires a Developer ID build (HUSHTYPE_SIGN_IDENTITY set when
# building) and a notarytool keychain profile:
#   xcrun notarytool store-credentials hushtype --apple-id <id> --team-id <team> --password <app-specific>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:-$(ls -t "$ROOT"/dist/Hushtype-*.dmg | head -1)}"
PROFILE="${HUSHTYPE_NOTARY_PROFILE:-hushtype}"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
