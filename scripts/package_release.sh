#!/usr/bin/env bash
# Builds a signed, notarized, stapled Pier DMG for distribution.
#
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
#   NOTARYTOOL_PROFILE="your-notary-profile" \
#   scripts/package_release.sh
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials your-notary-profile --apple-id you@example.com --team-id TEAMID
# Output: dist/Pier-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity}"
: "${NOTARYTOOL_PROFILE:?Set NOTARYTOOL_PROFILE to a notarytool keychain profile}"

VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' scripts/build_app.sh)"
DIST="dist"
STAGE="$DIST/stage"
DMG="$DIST/Pier-$VERSION.dmg"

echo "==> Building Pier $VERSION"
PIER_RELEASE=1 PIER_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" scripts/build_app.sh
codesign --verify --strict --verbose=2 build/Pier.app

echo "==> Creating $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Pier.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Pier" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"

echo "==> Notarizing (usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

shasum -a 256 "$DMG"
echo "==> Ready: $DMG"
