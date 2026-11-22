#!/bin/bash
# Run a VM through AndroiOSEngine.m on macOS using the macOS build of the
# engine (./build-ios.sh --platform=macos; ./build-angle.sh --platform=macos).
#   tests/run-engine-harness.sh <config.json> [seconds] [expect-string] [send]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
B="$HERE/build/macos"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -d "$B/QEMU.framework" ] || "$HERE/build-ios.sh" --platform=macos
clang -fobjc-arc -O1 -I"$HERE" -F"$B" -framework QEMU -framework Foundation \
  -framework IOSurface -framework CoreGraphics -framework ImageIO \
  -Wl,-rpath,"$B" "$HERE/AndroiOSEngine.m" "$HERE/tests/engine-harness.m" -o "$B/engine-harness"
exec "$B/engine-harness" "$@"
