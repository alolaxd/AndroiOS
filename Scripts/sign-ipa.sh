#!/bin/bash
# (Re-)sign an app bundle or .ipa ad-hoc with AndroiOS's entitlements, or with a
# real identity:  Scripts/sign-ipa.sh build/AndroiOS.ipa ["Apple Development: …"]
# Ad-hoc signatures work for TrollStore; AltStore/SideStore re-sign on install
# and keep the entitlements they find here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="$1"; ID="${2:--}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [[ "$IN" == *.ipa ]]; then (cd "$WORK" && unzip -q "$IN"); APP="$(echo "$WORK"/Payload/*.app)"; else APP="$IN"; fi
ENT="$WORK/ent.plist"
/usr/libexec/PlistBuddy -x -c "Print" "$ROOT/AndroiOS.entitlements" > "$ENT"
/usr/libexec/PlistBuddy -c "Add :get-task-allow bool true" "$ENT"   # lets StikDebug attach (JIT)
for fw in "$APP"/Frameworks/*.framework; do codesign --force --sign "$ID" --timestamp=none "$fw"; done
codesign --force --sign "$ID" --timestamp=none --entitlements "$ENT" "$APP"
codesign --verify --deep "$APP" && echo "signed: $APP"
if [[ "$IN" == *.ipa ]]; then (cd "$WORK" && rm -f "$IN" && zip -qry "$IN" Payload) && echo "→ $IN"; fi
