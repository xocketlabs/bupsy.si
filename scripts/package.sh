#!/bin/bash
# Builds Bupsy and packages it into a DMG — signed and notarized when the Apple secrets are
# present, ad-hoc signed when they are not.
#
# Runs locally and in CI with the same inputs, because a release process that only works on one
# machine is one nobody can verify or take over. Every secret comes from the environment; nothing
# is read from a keychain that happens to be set up a particular way.
#
# Two modes, chosen by whether DEVELOPER_ID is set:
#
#   Signed     DEVELOPER_ID, TEAM_ID, NOTARY_APPLE_ID, NOTARY_PASSWORD all set. Developer ID
#              signature, notarized, stapled. Opens with a double-click on any Mac.
#
#   Unsigned   None of them set. Ad-hoc signed, which Apple Silicon requires for the app to run at
#              all, but not notarized — so macOS asks the person to confirm the first open. This is
#              what ships until there is an Apple Developer account, and the release notes say so
#              plainly rather than leaving someone to discover Gatekeeper on their own.
#
# Setting only some of the signing secrets is an error, not a quiet fallback: a release that was
# meant to be notarized and silently is not would be found by users, not by us.
#
# Outputs, in $BUILD_DIR:
#   Bupsy-<version>.dmg     the versioned download
#   Bupsy.dmg               the same file under a fixed name, so "latest" links never change
#   Bupsy-<version>.dmg.sha256
set -euo pipefail

VERSION="${1:?usage: package.sh <version>}"
BUILD_DIR="${BUILD_DIR:-build}"
APP_NAME="Bupsy"

SIGNING_VARS=(DEVELOPER_ID TEAM_ID NOTARY_APPLE_ID NOTARY_PASSWORD)
present=0
for var in "${SIGNING_VARS[@]}"; do
  [ -n "${!var:-}" ] && present=$((present + 1))
done
if [ "$present" -eq "${#SIGNING_VARS[@]}" ]; then
  MODE=signed
elif [ "$present" -eq 0 ]; then
  MODE=unsigned
else
  echo "error: only $present of ${#SIGNING_VARS[@]} signing secrets are set (${SIGNING_VARS[*]})." >&2
  echo "       Set all of them to notarize, or none to build an unsigned DMG. See docs/05-release.md." >&2
  exit 1
fi
echo "==> Packaging $APP_NAME $VERSION ($MODE)"

echo "==> Generating project"
xcodegen generate

echo "==> Building"
rm -rf "$BUILD_DIR"
if [ "$MODE" = signed ]; then
  SIGN_ARGS=(
    CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID"
    CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
  )
else
  # Built unsigned, then ad-hoc signed as a whole below — signing during the build with "-"
  # leaves embedded frameworks inconsistently signed, which Apple Silicon then refuses to load.
  SIGN_ARGS=(CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild \
  -project Bupsy.xcodeproj \
  -scheme BupsyMac \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/dd" \
  -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
  "${SIGN_ARGS[@]}" \
  build | tail -5

APP="$BUILD_DIR/dd/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

echo "==> Signing ($MODE)"
if [ "$MODE" = signed ]; then
  # Sparkle ships helper tools that each need signing in their own right. Signing only the outer
  # bundle passes locally and fails notarization, which is a slow way to find out.
  find "$APP/Contents/Frameworks" \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) \
    2>/dev/null | while read -r item; do
      codesign --force --timestamp --options=runtime --sign "$DEVELOPER_ID" "$item" || true
    done
  codesign --force --deep --timestamp --options=runtime --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building DMG"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
STAGING="$BUILD_DIR/staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

if [ "$MODE" = signed ]; then
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
fi

cp "$DMG" "$BUILD_DIR/$APP_NAME.dmg"
SUM=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "$SUM  $(basename "$DMG")" > "$DMG.sha256"
echo "$MODE" > "$BUILD_DIR/mode"

echo "==> Done: $DMG ($MODE)"
echo "    sha256 $SUM"
