#!/bin/bash
# Build ANGLE (OpenGL ES → Metal) the way UTM does: WebKit's copy of ANGLE
# (the one Safari ships on iOS), from UTM's pinned WebKit fork, via its Xcode
# project. Output is packaged as EGL.framework + GLESv2.framework, the names
# UTM's libepoxy loads.
#   ./build-angle.sh --platform=device|simulator|macos
# Output: build/<platform>/angle/{EGL.framework,GLESv2.framework,include/}
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM=device
MIN_IOS=16.0
MIN_MAC=13.0
for arg in "$@"; do
  case "$arg" in
    --platform=*) PLATFORM="${arg#*=}" ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

WEBKIT_REPO=https://github.com/utmapp/WebKit.git
WEBKIT_COMMIT=ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10      # UTM patches/sources
WEBKIT="$HERE/build/src/WebKit.git"
TOOLS="$HERE/build/tools"

if [ ! -d "$WEBKIT/.git" ]; then
  git clone --filter=tree:0 --no-checkout "$WEBKIT_REPO" "$WEBKIT"
  git -C "$WEBKIT" sparse-checkout init
  git -C "$WEBKIT" sparse-checkout set Source/ThirdParty/ANGLE Configurations Tools/ccache
fi
git -C "$WEBKIT" checkout -q "$WEBKIT_COMMIT"
[ -d "$TOOLS/depot_tools" ] || git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$TOOLS/depot_tools"

case "$PLATFORM" in
  device)    SDK=iphoneos ;;
  simulator) SDK=iphonesimulator ;;
  macos)     SDK=macosx ;;
  *) echo "bad platform" >&2; exit 1 ;;
esac

ANGLE_SRC="$WEBKIT/Source/ThirdParty/ANGLE"
ARCHIVE="$HERE/build/$PLATFORM/angle-build/ANGLE"
rm -rf "$HERE/build/$PLATFORM/angle-build"
(cd "$ANGLE_SRC" && env -i PATH="$TOOLS/depot_tools:/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" HOME="$HOME" \
  xcodebuild archive -archivePath "$ARCHIVE" -derivedDataPath "$HERE/build/$PLATFORM/angle-dd" -scheme ANGLE -sdk "$SDK" -arch arm64 \
    -configuration Release \
    WEBCORE_LIBRARY_DIR=/usr/local/lib NORMAL_UMBRELLA_FRAMEWORKS_DIR="" \
    CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS" MACOSX_DEPLOYMENT_TARGET="$MIN_MAC" -quiet)

LIB="$ARCHIVE.xcarchive/Products/usr/local/lib"
DEST="$HERE/build/$PLATFORM/angle"
rm -rf "$DEST" && mkdir -p "$DEST/include"
rsync -a "$ANGLE_SRC/include/" "$DEST/include/"

# libX.dylib → X.framework (same layout as UTM's scripts/fixup.sh).
make_framework() { # name
  local name="$1" src="$LIB/lib$1.dylib" fw="$DEST/$1.framework" bin plist install_id
  if [ "$PLATFORM" = macos ]; then
    mkdir -p "$fw/Versions/A/Resources"; bin="$fw/Versions/A/$name"; plist="$fw/Versions/A/Resources/Info.plist"
    ln -sfh A "$fw/Versions/Current"; ln -sfh "Versions/Current/$name" "$fw/$name"
    ln -sfh Versions/Current/Resources "$fw/Resources"
    install_id="@rpath/$name.framework/Versions/A/$name"
  else
    mkdir -p "$fw"; bin="$fw/$name"; plist="$fw/Info.plist"
    install_id="@rpath/$name.framework/$name"
  fi
  cp "$src" "$bin"
  install_name_tool -id "$install_id" "$bin"
  # libEGL links libGLESv2: point it at the framework as well.
  for dep in $(otool -L "$bin" | awk '/libGLESv2\.dylib|libEGL\.dylib/ {print $1}'); do
    local d; d=$(basename "$dep" .dylib); d=${d#lib}
    if [ "$PLATFORM" = macos ]; then
      install_name_tool -change "$dep" "@rpath/$d.framework/Versions/A/$d" "$bin"
    else
      install_name_tool -change "$dep" "@rpath/$d.framework/$d" "$bin"
    fi
  done
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>com.androios.$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict></plist>
EOF
}
make_framework EGL
make_framework GLESv2
echo "ANGLE (WebKit, $PLATFORM) → $DEST"
otool -L "$DEST/EGL.framework/EGL" | head -5
