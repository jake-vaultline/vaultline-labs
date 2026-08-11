#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "usage: $0 /Volumes/NAME" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
volume_path="$1"
signing_identity="${IDENTITY:-F0C4C075498F5F67CBB94495DB0115D3DE89E835}"
probe_tmp="$(mktemp -d /tmp/vaultline-identity-probe.XXXXXX)"

cleanup() {
  if [[ "$probe_tmp" == /tmp/vaultline-identity-probe.* && -d "$probe_tmp" ]]; then
    find "$probe_tmp" -depth -delete
  fi
}
trap cleanup EXIT

probe_app="$probe_tmp/VolumeIdentityProbe.app"
mkdir -p "$probe_app/Contents/MacOS"

xcrun swiftc \
  "$app_dir/Sources/VolumeIdentity.swift" \
  "$script_dir/VolumeIdentityProbe.swift" \
  -framework DiskArbitration -framework IOKit \
  -o "$probe_app/Contents/MacOS/VolumeIdentityProbe"
cp "$script_dir/VolumeIdentityProbe-Info.plist" "$probe_app/Contents/Info.plist"

codesign --force --sign "$signing_identity" --options runtime \
  --entitlements "$app_dir/Resources/VaultlineIngest.entitlements" \
  "$probe_app"
codesign --verify --deep --strict --verbose=2 "$probe_app"

"$probe_app/Contents/MacOS/VolumeIdentityProbe" "$volume_path"
