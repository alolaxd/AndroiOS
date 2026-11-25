#!/bin/bash
# Turn on LineageOS's low-performance VM mode in a virtio_arm64only disk and
# write a zlib-compressed qcow2 (fits GitHub's 2 GB asset limit; QEMU reads it as-is).
#   Guest/make-lite.sh <vda.qcow2|vda.img> <out/vda.qcow2> [--low-perf]
#
# Sets in the EFI partition's grub.cfg (after its load_env):
#   android_nobootanim=1     -> no boot animation
#   android_lcd_density=320  -> phone layout (360 dp wide at 720x1280; the image's
#                               default of 160 dpi makes it a 720 dp tablet)
#   --low-perf: android_low_perf=1 -> androidboot.low_perf=1 (device/virt/virt-common
#                               init.low_performance.rc): ro.config.low_ram + Android Go
#                               LMK tuning, ro.hw_timeout_multiplier=50 (no ANR dialogs
#                               under emulation), setup wizard disabled.
#                               Works on LineageOS 22.2 (Android 15). On 23.2 (Android 16)
#                               SystemUI's WM Shell crashes in low-RAM mode
#                               ("unsupported windowingMode=5") until RescueParty
#                               drops to recovery, so don't use it there.
# Requires macOS (hdiutil/diskutil) and qemu-img (brew install qemu).
set -euo pipefail
IN="$1"; OUT="$2"; LOW_PERF=0
[ "${3:-}" = "--low-perf" ] && LOW_PERF=1
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
RAW="$WORK/vda.raw"

qemu-img convert -O raw "$IN" "$RAW"
DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$RAW" 2>/dev/null | head -1 | awk '{print $1}')
trap 'diskutil unmount "${DEV}s1" >/dev/null 2>&1; hdiutil detach "$DEV" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
diskutil mount "${DEV}s1" >/dev/null
MNT=$(diskutil info "${DEV}s1" | awk -F': *' '/Mount Point/{print $2}')
CFG="$MNT/boot/grub/grub.cfg"
[ -f "$CFG" ] || { echo "no grub.cfg in EFI partition" >&2; exit 1; }

python3 - "$CFG" "$LOW_PERF" <<'EOF'
import sys
p = sys.argv[1]; low_perf = sys.argv[2] == "1"; s = open(p).read()
marker = "# AndroiOS: low-performance VM defaults"
if marker not in s:
    # first "load_env ... grubenv android_..." line (inside set_kernel_cmdline_dynamic)
    i = s.index("load_env -f ${partition_persist}/grubenv android_"); j = s.index("\n", i) + 1
    lines = (["set android_low_perf=1"] if low_perf else []) + \
            ["set android_nobootanim=1", "set android_lcd_density=320"]
    s = s[:j] + "\t" + marker + "\n" + "".join("\t" + l + "\n" for l in lines) + s[j:]
    open(p, "w").write(s)
assert "set android_lcd_density=320" in open(p).read()
print("grub.cfg: nobootanim, density 320" + (", low_perf" if low_perf else ""))
EOF
diskutil unmount "${DEV}s1" >/dev/null
hdiutil detach "$DEV" >/dev/null
mkdir -p "$(dirname "$OUT")"
qemu-img convert -c -O qcow2 -o compression_type=zlib "$RAW" "$OUT"
qemu-img check "$OUT" | tail -1
ls -la "$OUT"
