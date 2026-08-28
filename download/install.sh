#!/bin/bash
#
# Vaultline Ingest installer.
#
#   curl -fsSL https://vaultline.io/ingest/install.sh | bash
#
# It downloads a notarized DMG, checks its SHA-256, copies the app to
# /Applications, and opens the standalone utility. It never installs anything else, never writes outside
# /Applications, and never asks for sudo.
#
set -euo pipefail

VERSION="0.2.1"
SHA256="dc035849d9786d2caf7d9f961cd25f18f3facb58f8c3e41aa83205623e9df523"
BASE="https://vaultline.io/ingest"
DMG="VaultlineIngest-${VERSION}.dmg"
APP="VaultlineIngest.app"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
die()  { printf "\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

bold "Vaultline Ingest ${VERSION}"

[[ "$(uname)" == "Darwin" ]] || die "This installer is for macOS."
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[[ "$MAJOR" -ge 13 ]] || die "macOS 13 or later is required (found $(sw_vers -productVersion))."

TMP="$(mktemp -d)"
cleanup() {
  [[ -d "$TMP/mnt" ]] && hdiutil detach "$TMP/mnt" -quiet >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "  Downloading…"
curl -fsSL "${BASE}/${DMG}" -o "$TMP/$DMG" || die "Download failed."

# Verify before mounting. A DMG that doesn't match the published checksum does
# not get opened, let alone installed.
echo "  Verifying…"
GOT=$(shasum -a 256 "$TMP/$DMG" | awk '{print $1}')
[[ "$GOT" == "$SHA256" ]] || die "Checksum mismatch. Not installing.
  expected $SHA256
  got      $GOT"

echo "  Installing…"
mkdir -p "$TMP/mnt"
hdiutil attach "$TMP/$DMG" -nobrowse -quiet -mountpoint "$TMP/mnt" || die "Couldn't open the disk image."

if [[ -d "/Applications/$APP" ]]; then
  echo "  Replacing the existing copy…"
  rm -rf "/Applications/$APP"
fi
cp -R "$TMP/mnt/$APP" /Applications/ || die "Couldn't copy to /Applications."
hdiutil detach "$TMP/mnt" -quiet

# Confirm what actually landed on disk is Apple-notarized. If Gatekeeper is
# unhappy, say so here rather than letting the user meet it as a scary dialog.
if ! spctl -a -t exec "/Applications/$APP" >/dev/null 2>&1; then
  echo "  ! macOS could not verify this copy. Remove it and download manually from ${BASE}."
fi

bold "Installed to /Applications/${APP}"

open -a "/Applications/$APP"

echo
echo "  Drop a card on the window to start. Nothing is ever moved or deleted —"
echo "  files are copied, then read back and checksummed before they're called done."
