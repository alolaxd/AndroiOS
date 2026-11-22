#!/bin/bash
# Build an unsigned AndroiOS.ipa. AltStore/SideStore/TrollStore re-sign on install.
#   Scripts/build-ipa.sh   ->  build/AndroiOS.ipa
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
[ -d Engine-C/build/device/libGLESv2.framework ] || Engine-C/build-angle.sh --platform=device
[ -d Engine-C/build/device/QEMU.framework ] || Engine-C/build-ios.sh --platform=device
command -v xcodegen >/dev/null && xcodegen generate --quiet
# Start from a clean bundle so no stale frameworks are shipped.
rm -rf build/DerivedData/Build/Products/Release-iphoneos/AndroiOS.app
xcodebuild -project AndroiOS.xcodeproj -scheme AndroiOS -sdk iphoneos -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build | grep -E " error: |\*\* BUILD"
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/AndroiOS.app build/ipa/Payload/
# Ad-hoc sign with the entitlements embedded: TrollStore installs this as-is, and
# AltStore/SideStore read entitlements from the existing signature when re-signing.
# get-task-allow lets StikDebug attach a debugger (that is what enables JIT).
APP=build/ipa/Payload/AndroiOS.app
ENT=build/ipa/signing.entitlements
/usr/libexec/PlistBuddy -x -c "Print" AndroiOS.entitlements > "$ENT"
/usr/libexec/PlistBuddy -c "Add :get-task-allow bool true" "$ENT"
for fw in "$APP"/Frameworks/*.framework; do codesign --force --sign - --timestamp=none "$fw"; done
codesign --force --sign - --timestamp=none --entitlements "$ENT" "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g;s/^/  entitlement: /'
rm -f build/AndroiOS.ipa
(cd build/ipa && zip -qry ../AndroiOS.ipa Payload)
echo "IPA: $ROOT/build/AndroiOS.ipa ($(du -h build/AndroiOS.ipa | cut -f1))"
