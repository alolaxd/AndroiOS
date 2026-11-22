#!/bin/bash
# Build an ad-hoc signed AndroiOS.ipa. AltStore/SideStore/TrollStore re-sign on install.
#   Scripts/build-ipa.sh               ->  build/AndroiOS.ipa
#   Scripts/build-ipa.sh --with-guest  ->  build/AndroiOS-LineageOS.ipa (~1 GB: LineageOS
#                                          23.2 inside the app, installed on first launch)
set -euo pipefail
WITH_GUEST=0
[ "${1:-}" = "--with-guest" ] && WITH_GUEST=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
[ -d Engine-C/build/device/angle/GLESv2.framework ] || Engine-C/build-angle.sh --platform=device
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
if [ "$WITH_GUEST" = 1 ]; then
  GUEST="$ROOT/Guest/build/lineage/LineageOS_on_arm64.utm/Data"
  [ -f "$GUEST/vda.qcow2" ] || "$ROOT/Guest/fetch-lineage.sh"
  mkdir -p "$APP/Guest/LineageOS"
  cp "$GUEST/efi_vars.fd" "$GUEST/vda.qcow2" "$GUEST/vdb.qcow2" "$APP/Guest/LineageOS/"
  echo "  bundled guest: $(du -sh "$APP/Guest/LineageOS" | cut -f1)"
fi
ENT=build/ipa/signing.entitlements
/usr/libexec/PlistBuddy -x -c "Print" AndroiOS.entitlements > "$ENT"
/usr/libexec/PlistBuddy -c "Add :get-task-allow bool true" "$ENT"
for fw in "$APP"/Frameworks/*.framework; do codesign --force --sign - --timestamp=none "$fw"; done
codesign --force --sign - --timestamp=none --entitlements "$ENT" "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g;s/^/  entitlement: /'
IPA=build/AndroiOS.ipa; [ "$WITH_GUEST" = 1 ] && IPA=build/AndroiOS-LineageOS.ipa
rm -f "$IPA"
(cd build/ipa && zip -qry "../$(basename "$IPA")" Payload)
echo "IPA: $ROOT/$IPA ($(du -h "$IPA" | cut -f1))"
