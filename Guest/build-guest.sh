#!/bin/bash
# Build the AndroiOS guest disk on a Mac (uses Homebrew QEMU + HVF for speed).
#   Guest/build-guest.sh   ->  Guest/build/{androios.qcow2,vmlinuz,initrd.img}
# Copy those three files into the app's Documents folder.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
B="$HERE/build"; mkdir -p "$B/export"
IMG_URL=https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img
DISK_SIZE=${DISK_SIZE:-14G}
QEMU=${QEMU:-qemu-system-aarch64}
FW=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd

if [ ! -f "$B/base.img" ]; then
  curl -fL --retry 3 -o "$B/base.img.part" "$IMG_URL"
  mv "$B/base.img.part" "$B/base.img"
fi
rm -f "$B/androios.qcow2" "$B/seed.iso" "$B/export/"*
qemu-img convert -O qcow2 -o cluster_size=2M "$B/base.img" "$B/androios.qcow2"
qemu-img resize -q "$B/androios.qcow2" "$DISK_SIZE"
hdiutil makehybrid -quiet -o "$B/seed.iso" -iso -joliet -default-volume-name cidata "$HERE/cloud-init"

echo "Provisioning (HVF). Serial log: $B/provision.log"
"$QEMU" -M virt -accel hvf -cpu host -smp 4 -m 4096 -bios "$FW" -nographic -no-reboot \
  -drive if=virtio,file="$B/androios.qcow2",cache=writeback \
  -drive if=virtio,file="$B/seed.iso",format=raw,media=cdrom,readonly=on \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -virtfs local,path="$B/export",mount_tag=export,security_model=none,id=export \
  -serial file:"$B/provision.log" -monitor none -display none

grep -q ANDROIOS_PROVISION_DONE "$B/provision.log" || { echo "provisioning failed, see $B/provision.log" >&2; exit 1; }
grep -ao "AIOS_[A-Z]*_[a-z0-9_-]*" "$B/provision.log" | sort -u
if grep -aq AIOS_MISSING "$B/provision.log" || ! grep -aq AIOS_OK_lineage_images "$B/provision.log"; then
  echo "a component failed to install, see $B/provision.log" >&2; exit 1
fi
mv "$B/export/vmlinuz" "$B/export/initrd.img" "$B/"
qemu-img info "$B/androios.qcow2" | grep -E "virtual size|disk size"
echo "Guest ready: $B/androios.qcow2 $B/vmlinuz $B/initrd.img"
