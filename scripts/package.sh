#!/bin/bash
# Builds, signs, notarizes and packages Bupsy into a DMG.
#
# Runs locally and in CI with the same inputs, because a release process that only works on one
# machine is one nobody can verify or take over. Every secret comes from the environment; nothing
# is read from a keychain that happens to be set up a particular way.
#
# Required:
#   DEVELOPER_ID          "Developer ID Application: Name (TEAMID)"
#   TEAM_ID               your Apple Developer team id
#   NOTARY_APPLE_ID       the Apple ID used for notarization
#   NOTARY_PASSWORD       an app-specific password for that Apple ID
set -euo pipefail

VERSION="${1:?usage: package.sh <version>}"
BUILD_DIR="${BUILD_DIR:-build}"
APP_NAME="Bupsy"

: "${DEVELOPER_ID:?set DEVELOPER_ID — see docs/05-release.md}"
: "${TEAM_ID:?set TEAM_ID}"
: "${NOTARY_APPLE_ID:?set NOTARY_APPLE_ID}"
: "${NOTARY_PASSWORD:?set NOTARY_PASSWORD}"

echo "==> Generating project"
xcodegen generate

echo "==> Building $APP_NAME $VERSION"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project Bupsy.xcodeproj \
  -scheme BupsyMac \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/dd" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  build

APP="$BUILD_DIR/dd/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }

# Sparkle ships helper tools that each need signing in their own right. Signing only the outer
# bundle passes locally and fails notarization, which is a slow way to find out.
echo "==> Signing embedded frameworks"
find "$APP/Contents/Frameworks" -name "*.framework" -o -name "*.xpc" -o -name "*.app" 2>/dev/null \
  | while read -r item; do
      codesign --force --timestamp --options=runtime --sign "$DEVELOPER_ID" "$item" || true
    done
codesign --force --deep --timestamp --options=runtime --sign "$DEVELOPER_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building DMG"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
STAGING="$BUILD_DIR/staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

echo "==> Notarizing (this takes a few minutes)"
xcrun notarytool submit "$DMG" \
  --apple-id "$NOTARY_APPLE_ID" \
  --password "$NOTARY_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait

# Stapling is what lets the DMG open on a Mac with no network. Skipping it produces a download
# that works on the machine that built it and fails for someone on a plane.
echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Done: $DMG"
echo "    $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
