#!/usr/bin/env bash
#
# Vaultline Labs Drive Inspector — release pipeline.
#
#   ./release.sh            build, sign, notarize, staple, package
#   ./release.sh --no-notarize   local test build, skip Apple round-trip
#
# One-time setup is in RELEASE.md. Run this from the app/ directory.
#
set -euo pipefail

SCHEME="VaultlineLabsDriveInspector"
PROJECT="$SCHEME.xcodeproj"
KEYCHAIN_PROFILE="vaultline-notary"
BUILD="build"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

say()  { printf "\n\033[1m▸ %s\033[0m\n" "$*"; }
fail() { printf "\n\033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

[[ -d "$PROJECT" ]] || fail "No $PROJECT here. Run from the app/ directory (xcodegen generate first)."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "0.0.0")
[[ "$VERSION" == "\$(MARKETING_VERSION)" ]] && VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*"\(.*\)".*/\1/')
DMG="$BUILD/$SCHEME-$VERSION.dmg"

rm -rf "$BUILD"; mkdir -p "$BUILD"

# ── 1. Archive ────────────────────────────────────────────────────────────
say "Archiving $SCHEME $VERSION"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
           -archivePath "$BUILD/$SCHEME.xcarchive" \
           clean archive | xcbeautify 2>/dev/null || \
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
           -archivePath "$BUILD/$SCHEME.xcarchive" clean archive

# ── 2. Export with Developer ID ───────────────────────────────────────────
say "Exporting signed app"
xcodebuild -exportArchive \
           -archivePath "$BUILD/$SCHEME.xcarchive" \
           -exportOptionsPlist ExportOptions.plist \
           -exportPath "$BUILD/export"

APP="$BUILD/export/$SCHEME.app"
[[ -d "$APP" ]] || fail "Export produced no .app"

# ── 3. THE GUARD ──────────────────────────────────────────────────────────
# The entire privacy claim is "this app cannot reach the network." If a
# network entitlement ever lands in the built binary, the claim becomes a
# lie and the release must not ship. This check is not optional.
say "Verifying the no-network claim"
ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)

if grep -q "com.apple.security.network" <<<"$ENTS"; then
  fail "A network entitlement is present. Refusing to ship — see Resources/*.entitlements"
fi
grep -q "com.apple.security.app-sandbox" <<<"$ENTS" || \
  fail "App Sandbox is OFF. Without it the missing network entitlement is unenforced and the claim is meaningless."
grep -q "com.apple.security.files.user-selected" <<<"$ENTS" || \
  fail "No user-selected file access. The app can't read a drive or save a report."
grep -q "com.apple.security.files.all" <<<"$ENTS" && \
  fail "Broad filesystem entitlement present. This app only ever sees what the user hands it."
echo "  ✓ sandboxed · no network entitlement · user-selected files only"

say "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Runtime" || true
grep -q "runtime" <<<"$(codesign -d --verbose=4 "$APP" 2>&1)" || \
  echo "  ! Hardened Runtime flag not detected — notarization will reject this"

# ── 4. DMG ────────────────────────────────────────────────────────────────
say "Building DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Vaultline Labs Drive Inspector" \
               -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "  ✓ $DMG"

# ── 5. Notarize + staple ──────────────────────────────────────────────────
if [[ $NOTARIZE -eq 1 ]]; then
  say "Notarizing (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

  say "Stapling"
  # Staple the app first, then re-package, so a user who drags the app out of
  # the DMG still has a stapled ticket. Stapling only the DMG leaves the copied
  # app dependent on a network check at first launch.
  xcrun stapler staple "$APP"
  rm -f "$DMG"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Vaultline Labs Drive Inspector" \
                 -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  xcrun stapler staple "$DMG"

  say "Final gatekeeper check"
  xcrun stapler validate "$DMG"
  spctl -a -vvv -t install "$APP" 2>&1 | sed 's/^/  /'
else
  echo "  (skipped notarization — this build will be blocked on other Macs)"
fi

say "Done"
echo "  $DMG"
echo "  $(du -h "$DMG" | cut -f1)"
echo
echo "Ship it: upload the DMG, update the download page's version and size."
