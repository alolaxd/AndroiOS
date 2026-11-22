#!/bin/bash
# Full build: ANGLE → engine deps + QEMU → Xcode app → .ipa
#   Scripts/build-all.sh            (device)
#   PLATFORMS="device simulator macos" Scripts/build-all.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
git -C "$ROOT" submodule update --init Engine-C/qemu
for P in ${PLATFORMS:-device}; do
  "$ROOT/Engine-C/build-angle.sh" --platform="$P"
  "$ROOT/Engine-C/build-ios.sh" --platform="$P"
done
"$ROOT/Scripts/build-ipa.sh"
