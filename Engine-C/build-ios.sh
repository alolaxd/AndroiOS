#!/bin/bash
# Cross-compile the AndroiOS engine (QEMU + deps) for iOS.
#
#   ./build-ios.sh                       # device (arm64-apple-ios)
#   ./build-ios.sh --platform=simulator  # Apple-silicon simulator
#   ./build-ios.sh --clean               # wipe build dir for that platform first
#
# Output: build/<platform>/QEMU.framework  (QEMU system emulator as a dylib)
#         build/<platform>/prefix          (static deps: glib, pixman, ...)
#
# Why a dylib and not libqemu.a: QEMU registers every machine/device/accelerator
# with __attribute__((constructor)) type_init() calls. A static archive only pulls
# in referenced objects, so all of those registrations would be dropped silently.
# Linking QEMU as one dylib keeps every object (same as upstream's executable).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM=device
MIN_IOS=16.0
CLEAN=0
JOBS=$(sysctl -n hw.ncpu)

for arg in "$@"; do
  case "$arg" in
    --platform=*) PLATFORM="${arg#*=}" ;;
    --min-ios=*)  MIN_IOS="${arg#*=}" ;;
    --clean)      CLEAN=1 ;;
    -h|--help)    sed -n 2,14p "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

case "$PLATFORM" in
  device)    SDK_NAME=iphoneos;        TRIPLE="arm64-apple-ios${MIN_IOS}" ;;
  simulator) SDK_NAME=iphonesimulator; TRIPLE="arm64-apple-ios${MIN_IOS}-simulator" ;;
  macos)     SDK_NAME=macosx;          TRIPLE="arm64-apple-macos13.0" ;;   # host test harness
  *) echo "platform must be device, simulator or macos" >&2; exit 1 ;;
esac

# Use the full Xcode even if xcode-select points at the Command Line Tools.
if ! xcrun --sdk "$SDK_NAME" --show-sdk-path >/dev/null 2>&1; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
SDK="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"

# ---- versions ---------------------------------------------------------------
GLIB_VER=2.84.4
PIXMAN_VER=0.46.4
SLIRP_VER=4.9.1

BUILD="$HERE/build/$PLATFORM"
SRC="$HERE/build/src"          # downloaded tarballs, shared between platforms
PREFIX="$BUILD/prefix"
VENV="$HERE/build/venv"
PATCHES="$HERE/ios-patches"

[ "$CLEAN" = 1 ] && rm -rf "$BUILD"
mkdir -p "$BUILD" "$SRC" "$PREFIX"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---- host tools (meson/ninja in a private venv) -----------------------------
if [ ! -x "$VENV/bin/meson" ]; then
  log "Creating build venv (meson, ninja)"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q 'meson>=1.5,<1.9' ninja packaging distlib pyyaml
fi
export PATH="$VENV/bin:$PATH"

# ---- toolchain --------------------------------------------------------------
CC_BIN="$(xcrun --sdk "$SDK_NAME" -f clang)"
CXX_BIN="$(xcrun --sdk "$SDK_NAME" -f clang++)"
AR_BIN="$(xcrun --sdk "$SDK_NAME" -f ar)"
STRIP_BIN="$(xcrun --sdk "$SDK_NAME" -f strip)"
NM_BIN="$(xcrun --sdk "$SDK_NAME" -f nm)"
RANLIB_BIN="$(xcrun --sdk "$SDK_NAME" -f ranlib)"
ARCH_FLAGS="-target $TRIPLE -isysroot $SDK"
CFLAGS_COMMON="$ARCH_FLAGS -O2 -fno-common"

export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

CROSS="$BUILD/ios-cross.txt"
cat > "$CROSS" <<EOF
[binaries]
c = ['$CC_BIN', '-target', '$TRIPLE', '-isysroot', '$SDK']
objc = ['$CC_BIN', '-target', '$TRIPLE', '-isysroot', '$SDK']
cpp = ['$CXX_BIN', '-target', '$TRIPLE', '-isysroot', '$SDK']
ar = '$AR_BIN'
strip = '$STRIP_BIN'
nm = '$NM_BIN'
ranlib = '$RANLIB_BIN'
pkg-config = '$(command -v pkg-config)'

[built-in options]
c_args = ['-O2', '-fno-common', '-I$PREFIX/include']
objc_args = ['-O2', '-fno-common', '-I$PREFIX/include']

[properties]
pkg_config_libdir = '$PREFIX/lib/pkgconfig'
needs_exe_wrapper = $( [ "$PLATFORM" = macos ] && echo false || echo true )

[host_machine]
system = 'darwin'
subsystem = '$(case $PLATFORM in (simulator) echo ios-simulator;; (macos) echo macos;; (*) echo ios;; esac)'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF

fetch() { # url dest-dir-name
  local url="$1" name="$2" tarball="$SRC/$(basename "$1")"
  if [ ! -d "$SRC/$name" ]; then
    [ -f "$tarball" ] || { log "Downloading $(basename "$url")"; curl -fL --retry 3 -o "$tarball.part" "$url" && mv "$tarball.part" "$tarball"; }
    mkdir -p "$SRC/.x" && tar -xf "$tarball" -C "$SRC/.x" && mv "$SRC/.x/$name" "$SRC/$name" && rmdir "$SRC/.x"
  fi
}

meson_dep() { # name srcdir [meson args...]
  local name="$1" src="$2"; shift 2
  if [ -f "$BUILD/.done-$name" ]; then return; fi
  log "Building $name ($PLATFORM)"
  rm -rf "$BUILD/$name"
  meson setup "$BUILD/$name" "$src" --cross-file "$CROSS" --prefix "$PREFIX" \
    --default-library=static --buildtype=release "$@"
  meson compile -C "$BUILD/$name" -j "$JOBS"
  meson install -C "$BUILD/$name" --quiet
  touch "$BUILD/.done-$name"
}

# ---- glib (pulls libffi, pcre2, proxy-libintl in as meson subprojects) ------
fetch "https://download.gnome.org/sources/glib/${GLIB_VER%.*}/glib-$GLIB_VER.tar.xz" "glib-$GLIB_VER"
meson_dep glib "$SRC/glib-$GLIB_VER" \
  -Dtests=false -Dintrospection=disabled -Dnls=disabled -Dlibmount=disabled \
  -Dselinux=disabled -Dxattr=false -Ddtrace=disabled -Dsystemtap=disabled \
  -Dsysprof=disabled -Dman-pages=disabled -Ddocumentation=false -Dglib_debug=disabled \
  --force-fallback-for=libffi,libpcre2-8,pcre2 -Dpcre2:test=false -Dpcre2:grep=false -Dpcre2:jit=disabled

# ---- pixman -----------------------------------------------------------------
fetch "https://cairographics.org/releases/pixman-$PIXMAN_VER.tar.gz" "pixman-$PIXMAN_VER"
meson_dep pixman "$SRC/pixman-$PIXMAN_VER" -Dtests=disabled -Ddemos=disabled \
  -Dgtk=disabled -Dlibpng=disabled -Dopenmp=disabled -Da64-neon=disabled

# ---- libslirp (usermode networking; no raw sockets needed) ------------------
fetch "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v$SLIRP_VER/libslirp-v$SLIRP_VER.tar.gz" "libslirp-v$SLIRP_VER"
meson_dep slirp "$SRC/libslirp-v$SLIRP_VER"

apply_patch_once() { # srcdir patch
  [ -f "$1/.aios-patched" ] && return
  patch -d "$1" -p1 --forward < "$2"
  touch "$1/.aios-patched"
}

# ---- GPU translation layer --------------------------------------------------
# guest Mesa virgl → virtio-gpu → virglrenderer → libepoxy → ANGLE → Metal
# These are UTM's pinned, iOS-proven components (utmapp/UTM patches/sources).
EPOXY_REPO=https://github.com/utmapp/libepoxy.git
EPOXY_COMMIT=bf98587477fe68d07b93319ece7b40a7d0e2eabe
VIRGL_REPO=https://github.com/utmapp/virglrenderer.git
VIRGL_COMMIT=dd0652b13e589c4c124ea79123a3adcd85173f4f

git_fetch() { # repo commit dir
  [ -d "$3/.git" ] || git clone -q "$1" "$3"
  git -C "$3" checkout -q "$2"
}

# Khronos EGL/GLES headers come from WebKit's ANGLE (build-angle.sh installs them).
ANGLE_DIR="$BUILD/angle"
[ -f "$ANGLE_DIR/include/EGL/eglplatform.h" ] || { echo "error: run ./build-angle.sh --platform=$PLATFORM first" >&2; exit 1; }
mkdir -p "$PREFIX/include"
rsync -a "$ANGLE_DIR/include/" "$PREFIX/include/"

# libepoxy (UTM fork): loads ANGLE as EGL.framework / GLESv2.framework.
git_fetch "$EPOXY_REPO" "$EPOXY_COMMIT" "$SRC/utm-libepoxy"
meson_dep epoxy-utm "$SRC/utm-libepoxy" -Dtests=false -Dglx=no -Degl=yes -Dx11=false

# virglrenderer (UTM fork): many Apple/ANGLE host fixes over upstream.
# Venus/Neptune need Vulkan (MoltenVK) and are not used by the virgl GL path.
git_fetch "$VIRGL_REPO" "$VIRGL_COMMIT" "$SRC/utm-virglrenderer"
meson_dep virglrenderer-utm "$SRC/utm-virglrenderer" -Dtests=false -Dcheck-gl-errors=false \
  -Dvenus=false -Dneptune=false -Dvideo=false -Ddrm-renderers=[]

# ---- QEMU -------------------------------------------------------------------
QEMU_SRC="$HERE/qemu"
if [ ! -f "$QEMU_SRC/.aios-patched" ]; then
  log "Applying iOS patches to QEMU"
  for p in "$PATCHES"/qemu-*.patch; do
    echo "  $(basename "$p")"
    git -C "$QEMU_SRC" apply --whitespace=nowarn "$p"
  done
  touch "$QEMU_SRC/.aios-patched"
fi

QB="$BUILD/qemu"
# Reconfigure whenever the configure invocation below changes.
CONF_STAMP="$(sed -n '/^: QEMU_CONFIGURE_BEGIN/,/^: QEMU_CONFIGURE_END/p' "$0" | shasum | cut -c1-12)"
if [ ! -f "$QB/build.ninja" ] || [ "$(cat "$QB/.conf-stamp" 2>/dev/null)" != "$CONF_STAMP" ]; then
  rm -rf "$QB"
: QEMU_CONFIGURE_BEGIN
  log "Configuring QEMU ($PLATFORM)"
  mkdir -p "$QB"
  (cd "$QB" && \
    CC="$CC_BIN" OBJCC="$CC_BIN" CXX="$CXX_BIN" AR="$AR_BIN" NM="$NM_BIN" \
    STRIP="$STRIP_BIN" RANLIB="$RANLIB_BIN" PKG_CONFIG="$(command -v pkg-config)" \
    "$QEMU_SRC/configure" \
      --prefix="$PREFIX" \
      --cross-prefix="" \
      --target-list=aarch64-softmmu \
      --extra-cflags="$ARCH_FLAGS" \
      --extra-objcflags="$ARCH_FLAGS" \
      --extra-ldflags="$ARCH_FLAGS" \
      --enable-tcg \
      --disable-kvm --disable-xen --disable-hvf \
      --disable-bsd-user --disable-linux-user \
      --disable-tools --disable-docs --disable-guest-agent \
      --disable-cocoa --disable-sdl --disable-gtk --disable-vnc \
      --disable-coreaudio --disable-curses --disable-libusb --disable-usb-redir \
      --disable-capstone --disable-libssh --disable-curl --disable-gnutls \
      --disable-nettle --disable-gcrypt --disable-zstd --disable-lzo --disable-snappy \
      --disable-bzip2 --disable-vmnet --disable-plugins \
      --disable-qom-cast-debug --disable-werror \
      --enable-slirp --enable-pixman --enable-opengl --enable-virglrenderer \
      --without-default-features --enable-system \
      -Dios_library=true )
  echo "$CONF_STAMP" > "$QB/.conf-stamp"
: QEMU_CONFIGURE_END
fi
log "Building QEMU ($PLATFORM)"
ninja -C "$QB" -j "$JOBS"

# ---- package as QEMU.framework ---------------------------------------------
log "Packaging QEMU.framework"
DYLIB="$QB/libqemu-system-aarch64.dylib"
FW="$BUILD/QEMU.framework"
rm -rf "$FW" && mkdir -p "$FW/Headers"
cp "$DYLIB" "$FW/QEMU"
install_name_tool -id "@rpath/QEMU.framework/QEMU" "$FW/QEMU"
cp "$QEMU_SRC/include/qemu-ios-api.h" "$FW/Headers/qemu-ios-api.h"
cat > "$FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>QEMU</string>
  <key>CFBundleIdentifier</key><string>org.qemu.QEMU</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$(cat "$QEMU_SRC/VERSION")</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$MIN_IOS</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$(case $PLATFORM in (simulator) echo iPhoneSimulator;; (macos) echo MacOSX;; (*) echo iPhoneOS;; esac)</string></array>
</dict></plist>
EOF

# Firmware blobs QEMU needs at runtime (shipped as app resources).
mkdir -p "$BUILD/pc-bios"
cp "$QEMU_SRC/pc-bios/keymaps/en-us" "$BUILD/pc-bios/" 2>/dev/null || true
if [ -f "$QEMU_SRC/pc-bios/edk2-aarch64-code.fd.bz2" ]; then
  bunzip2 -kc "$QEMU_SRC/pc-bios/edk2-aarch64-code.fd.bz2" > "$BUILD/pc-bios/edk2-aarch64-code.fd"
fi

# ANGLE frameworks (built by build-angle.sh) are loaded by libepoxy at runtime.
rm -rf "$BUILD/EGL.framework" "$BUILD/GLESv2.framework" "$BUILD/libEGL.framework" "$BUILD/libGLESv2.framework"
cp -R "$ANGLE_DIR/EGL.framework" "$ANGLE_DIR/GLESv2.framework" "$BUILD/"

log "Done: $FW"
otool -L "$FW/QEMU" | sed -n 1,20p
