#!/usr/bin/env bash
#
# Vaultline Ingest — release pipeline.
#
#   ./release.sh                  build, sign, notarize, staple, package
#   ./release.sh --no-notarize    Developer ID-signed internal candidate
#   ./release.sh --review         ad-hoc signed review DMG; no protected credential
#
# Setup is in RELEASE.md. Run from the app/ directory.
#
set -euo pipefail

SCHEME="VaultlineIngest"
PROJECT="$SCHEME.xcodeproj"
KEYCHAIN_PROFILE="vaultline-notary"
BUILD="build"
NOTARIZE=1
REVIEW=0
case "${1:-}" in
  "") ;;
  --no-notarize) NOTARIZE=0 ;;
  --review) NOTARIZE=0; REVIEW=1 ;;
  *) printf "Unknown option: %s\n" "$1" >&2; exit 2 ;;
esac

say()  { printf "\n\033[1m▸ %s\033[0m\n" "$*"; }
fail() { printf "\n\033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

[[ -d "$PROJECT" ]] || fail "No $PROJECT here. Run from app/ (xcodegen generate first)."

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*"\(.*\)".*/\1/')
if [[ $REVIEW -eq 1 ]]; then
  DMG="$BUILD/$SCHEME-$VERSION-review.dmg"
else
  DMG="$BUILD/$SCHEME-$VERSION.dmg"
fi

rm -rf "$BUILD"; mkdir -p "$BUILD"

say "Archiving $SCHEME $VERSION"
ARCHIVE_ARGS=(
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release
  -archivePath "$BUILD/$SCHEME.xcarchive" clean archive
)
if [[ $REVIEW -eq 1 ]]; then
  ARCHIVE_ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
xcodebuild "${ARCHIVE_ARGS[@]}"

say "Preparing the signed app"
# The archive product is already a Developer ID–signed, hardened, universal app.
# Package it directly so a stale duplicate certificate in the local keychain
# cannot make Xcode's otherwise-redundant export re-sign step choose the wrong key.
mkdir -p "$BUILD/export"
APP="$BUILD/export/$SCHEME.app"
ditto "$BUILD/$SCHEME.xcarchive/Products/Applications/$SCHEME.app" "$APP"
[[ -d "$APP" ]] || fail "Archive produced no .app"

# ── THE GUARD ─────────────────────────────────────────────────────────────
# Ingest is an offline utility. It can neither initiate nor accept a network
# connection and never gains an entitlement nobody asked for.
say "Verifying the entitlement contract"
ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)

grep -q "com.apple.security.app-sandbox" <<<"$ENTS" \
  || fail "App Sandbox is OFF. This app writes to people's drives; it stays sandboxed."
grep -Eq "com.apple.security.network.(client|server)" <<<"$ENTS" \
  && fail "Network entitlement present. Standalone Ingest must remain offline."
grep -q "com.apple.security.files.all" <<<"$ENTS" \
  && fail "Broad filesystem entitlement present. This app only ever sees what the user hands it."
grep -q "com.apple.security.files.user-selected.read-write" <<<"$ENTS" \
  || fail "Missing user-selected read-write. The app can't write destinations."
echo "  ✓ sandboxed · no network entitlement · user-selected files only"

# Cheap tripwire for the product boundary. Network behavior belongs in other
# products and must not enter the standalone Ingest binary.
say "Checking the network surface"
NETWORK_CALLS=$(grep -Erl 'URLSession[[:space:]]*\(|URLSession\.shared|NW(Connection|Listener)[[:space:]]*\(|WKWebView[[:space:]]*\(|CF(Read|Write)Stream|Process[[:space:]]*\(' Sources || true)
if [[ -n "$NETWORK_CALLS" ]]; then
  fail "Standalone Ingest contains a network-capable code path:
$NETWORK_CALLS
Network clients and shell-outs belong in separate products."
fi
echo "  ✓ no network or shell client in the app sources"

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
elif [[ $REVIEW -eq 1 ]]; then
  echo "Ad-hoc review candidate only — Developer ID signing, notarization, and stapling were not attempted."
  echo "Do not update the public installer or upload this DMG."
else
  echo "Developer ID-signed internal candidate only — notarization and stapling were skipped."
  echo "Do not update the public installer or upload this DMG."
fi
