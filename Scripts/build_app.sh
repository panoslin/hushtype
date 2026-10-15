#!/bin/bash
# Builds dist/Hushtype.app (release). Signs with $HUSHTYPE_SIGN_IDENTITY (a "Developer ID Application"
# identity) when set, otherwise ad-hoc for local use.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${HUSHTYPE_VERSION:-0.1.0}"
BUILD="${HUSHTYPE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="$ROOT/dist/Hushtype.app"
# QA=1: test build with the QA launch arguments compiled in (never shipped), in .build/qa-app/
FLAGS=()
if [ "${QA:-0}" = 1 ]; then FLAGS=(-Xswiftc -DHUSHTYPE_QA); APP="$ROOT/.build/qa-app/Hushtype QA.app"; fi

swift build -c release --product Hushtype ${FLAGS[@]+"${FLAGS[@]}"}
swift build -c release --product hushtype-engine ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release --show-bin-path)"

case "$APP" in "$ROOT"/dist/*|"$ROOT"/.build/qa-app/*) ;; *) echo "refusing to touch $APP" >&2; exit 1;; esac
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Hushtype" "$APP/Contents/MacOS/Hushtype"
cp "$BIN/hushtype-engine" "$APP/Contents/MacOS/hushtype-engine"
cp Vendor/SherpaOnnx/lib/libsherpa-onnx-c-api.dylib Vendor/SherpaOnnx/lib/libonnxruntime.dylib "$APP/Contents/Frameworks/"
cp Resources/Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f Resources/Sounds/droplet-start.wav ] || python3 Scripts/make_sounds.py Resources/Sounds droplet
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Sounds"
cp Resources/Sounds/droplet-*.wav "$APP/Contents/Resources/Sounds/"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/Licenses"
cp Vendor/SherpaOnnx/LICENSE "$APP/Contents/Resources/Licenses/sherpa-onnx-LICENSE.txt"
[ -f .build/checkouts/WhisperKit/LICENSE ] && cp .build/checkouts/WhisperKit/LICENSE "$APP/Contents/Resources/Licenses/WhisperKit-LICENSE.txt"

# Signing identity, in order: $HUSHTYPE_SIGN_IDENTITY (Developer ID, for release), the local
# self-signed "Hushtype Local Dev" certificate (keeps macOS permissions across rebuilds), ad-hoc.
DEV_ID="$(security find-identity -p codesigning 2>/dev/null | awk '/"Hushtype Local Dev"/{print $2; exit}')"
IDENTITY="${HUSHTYPE_SIGN_IDENTITY:-${DEV_ID:--}}"
# Ad-hoc signatures carry no Team ID, so hardened-runtime library validation would refuse to load
# the bundled dylibs; only enable the hardened runtime for real Developer ID builds (required for
# notarization), where app and dylibs share the Team ID.
SIGN=(codesign --force --timestamp=none --sign "$IDENTITY")
[ -n "${HUSHTYPE_SIGN_IDENTITY:-}" ] && SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
for lib in "$APP"/Contents/Frameworks/*.dylib; do "${SIGN[@]}" "$lib"; done
"${SIGN[@]}" "$APP/Contents/MacOS/hushtype-engine"
"${SIGN[@]}" --entitlements Resources/Hushtype.entitlements "$APP"
codesign --verify --deep --strict "$APP" 2>/dev/null || [ -z "${HUSHTYPE_SIGN_IDENTITY:-}" ]
echo "built $APP ($VERSION build $BUILD, signed: $IDENTITY)"
