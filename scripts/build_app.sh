#!/usr/bin/env bash
# Builds Pier.app into ./build, signs it, and optionally installs it to /Applications.
#
#   scripts/build_app.sh             # release build -> build/Pier.app
#   scripts/build_app.sh --install   # ...and replace /Applications/Pier.app, then relaunch
#   scripts/build_app.sh --icon      # also regenerate Resources/AppIcon.icns from Tools/make_icon.swift
#
# Signing: uses $PIER_SIGN_IDENTITY if set, else the first "Developer ID Application" or
# "Apple Development" identity in your keychain, else ad-hoc. A stable identity matters: macOS ties
# Accessibility / Screen Recording grants to the signature, so ad-hoc builds lose them on every rebuild.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="1.0.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="$ROOT/build/Pier.app"
INSTALL=0
ICON=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --icon) ICON=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ $ICON -eq 1 || ! -f Resources/AppIcon.icns ]]; then
  echo "==> Rendering icon"
  TMP="$(mktemp -d)"
  swift Tools/make_icon.swift "$TMP/AppIcon.iconset"
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

echo "==> Building (release)"
# A clean build avoids SwiftPM occasionally shipping stale objects in release mode.
swift package clean
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Pier"
[[ -x "$BIN" ]] || { echo "Build output not found at $BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pier"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

IDENTITY="${PIER_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development)' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [[ -n "$IDENTITY" ]]; then
  echo "==> Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp=none \
    --entitlements Resources/Pier.entitlements --sign "$IDENTITY" "$APP"
else
  echo "==> No signing identity found; signing ad-hoc"
  codesign --force --entitlements Resources/Pier.entitlements --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "==> Built $APP"

if [[ $INSTALL -eq 1 ]]; then
  DEST="/Applications/Pier.app"
  echo "==> Installing to $DEST"
  # Quit only the Pier we installed before (by bundle id), never other processes.
  osascript -e 'tell application id "com.logicoutloud.Pier" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -f "/Applications/Pier.app/Contents/MacOS/Pier" >/dev/null || break
    sleep 0.25
  done
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "==> Pier is running from $DEST"
fi
