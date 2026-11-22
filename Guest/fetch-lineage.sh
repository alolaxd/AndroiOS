#!/bin/bash
# Fetch the prebuilt LineageOS virtio_arm64only VM (jqssun/android-lineage-qemu,
# built by GitHub Actions with build-provenance attestations) and verify it.
#   Guest/fetch-lineage.sh [release-tag]   (default v2026.10.18 = LineageOS 23.2, Android 16)
# Output: Guest/build/lineage/LineageOS_on_arm64.utm/Data/{efi_vars.fd,vda.qcow2,vdb.qcow2}
# Copy those three files to the device; the app's setup wizard detects the UEFI layout.
#
# Graphics: this build renders Android with Mesa virgl on virtio-gpu and presents via
# drm_hwcomposer, i.e. straight onto AndroiOS's GPU path (virgl → ANGLE → Metal).
set -euo pipefail
TAG="${1:-v2026.10.18}"
REPO=jqssun/android-lineage-qemu
OUT="$(cd "$(dirname "$0")" && pwd)/build/lineage"
mkdir -p "$OUT" && cd "$OUT"
gh release download "$TAG" -R "$REPO" -p 'UTM-VM-lineage-*-virtio_arm64only.zip' --clobber
ZIP=$(ls UTM-VM-lineage-*-virtio_arm64only.zip | head -1)
gh attestation verify "$ZIP" -R "$REPO" >/dev/null && echo "attestation OK: $ZIP"
rm -rf LineageOS_on_arm64.utm && unzip -q "$ZIP"
ls -la LineageOS_on_arm64.utm/Data
