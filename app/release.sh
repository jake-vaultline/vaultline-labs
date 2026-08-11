#!/usr/bin/env bash
#
# Vaultline Ingest — release pipeline.
#
#   ./release.sh                  build, sign, notarize, staple, package
#   ./release.sh --no-notarize    local test build
#
# Setup is in RELEASE.md. Run from the app/ directory.
#
set -euo pipefail

SCHEME="VaultlineIngest"
PROJECT="$SCHEME.xcodeproj"
KEYCHAIN_PROFILE="vaultline-notary"
BUILD="build"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

say()  { printf "\n\033[1m▸ %s\033[0m\n" "$*"; }
fail() { printf "\n\033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

[[ -d "$PROJECT" ]] || fail "No $PROJECT here. Run from app/ (xcodegen generate first)."

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*"\(.*\)".*/\1/')
DMG="$BUILD/$SCHEME-$VERSION.dmg"

rm -rf "$BUILD"; mkdir -p "$BUILD"

say "Archiving $SCHEME $VERSION"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
           -archivePath "$BUILD/$SCHEME.xcarchive" clean archive

say "Preparing the signed app"
# The archive product is already a Developer ID–signed, hardened, universal app.
# Package it directly so a stale duplicate certificate in the local keychain
# cannot make Xcode's otherwise-redundant export re-sign step choose the wrong key.
mkdir -p "$BUILD/export"
APP="$BUILD/export/$SCHEME.app"
ditto "$BUILD/$SCHEME.xcarchive/Products/Applications/$SCHEME.app" "$APP"
[[ -d "$APP" ]] || fail "Archive produced no .app"

# ── THE GUARD ─────────────────────────────────────────────────────────────
# Inverse of Drive Inspector's. Ingest is ALLOWED the network — pairing to a
# Media Nexus is the point — but the promise is that it can never be a server,
# can never reach outside the sandbox, and never gains an entitlement nobody
# asked for. Check what's there, and what must not be.
say "Verifying the entitlement contract"
ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)

grep -q "com.apple.security.app-sandbox" <<<"$ENTS" \
  || fail "App Sandbox is OFF. This app writes to people's drives; it stays sandboxed."
grep -q "com.apple.security.network.server" <<<"$ENTS" \
  && fail "network.server present. This app is a client only — it never listens."
grep -q "com.apple.security.files.all" <<<"$ENTS" \
  && fail "Broad filesystem entitlement present. This app only ever sees what the user hands it."
grep -q "com.apple.security.files.user-selected.read-write" <<<"$ENTS" \
  || fail "Missing user-selected read-write. The app can't write destinations."
echo "  ✓ sandboxed · client-only network · user-selected files only"

# Cheap tripwire for the Network panel's honesty: every request is supposed to
# go through the two audited service clients. If another file starts creating URLSessions,
# that panel silently stops being complete evidence.
say "Checking the network surface"
SESSIONS=$(grep -Erl 'URLSession[[:space:]]*\(|URLSession\.shared' Sources | grep -Ev "(NexusClient|DrivePassportClient)\.swift" || true)
if [[ -n "$SESSIONS" ]]; then
  fail "URLSession created outside the audited service clients:
$SESSIONS
Every request must go through NexusClient or DrivePassportClient or the Network panel is decoration."
fi
echo "  ✓ all network traffic routes through the audited service clients"

say "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

say "Building DMG"
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Vaultline Ingest" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "  ✓ $DMG"

if [[ $NOTARIZE -eq 1 ]]; then
  say "Notarizing (a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

  say "Stapling"
  # Staple the app, repackage around it, then staple the DMG — otherwise an app
  # dragged out of the DMG and first launched offline fails Gatekeeper.
  xcrun stapler staple "$APP"
  rm -f "$DMG"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Vaultline Ingest" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  xcrun stapler staple "$DMG"

  say "Gatekeeper check"
  xcrun stapler validate "$DMG"
  spctl -a -vvv -t install "$APP" 2>&1 | sed 's/^/  /'
fi

say "Checksum for the install script"
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "  $SHA"
echo
if [[ $NOTARIZE -eq 1 ]]; then
  echo "Update these in download/install.sh:"
  echo "  VERSION=\"$VERSION\""
  echo "  SHA256=\"$SHA\""
  echo
  echo "Then upload $DMG"
else
  echo "Local release candidate only — notarization and stapling were skipped."
  echo "Do not update the public installer or upload this DMG."
fi
