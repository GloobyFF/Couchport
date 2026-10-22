#!/bin/bash
# Builds chiaki (via the Pylux fork, which already has a lib-only Apple-mobile
# CMake path with mbedTLS/opus/json-c/miniupnpc fetched from source) for
# visionOS and iOS (device + simulator), compiles our ChiakiShim/vp_chiaki.c INSIDE the
# library, and packages everything as Frameworks/VPChiaki.xcframework with a
# Clang module named `VPChiaki` (Swift: `import VPChiaki`).
#
# Usage:   ./Tools/build_libchiaki_visionos.sh            # visionOS + iOS, device + simulator
#          VP_SKIP_SIM=1 ./Tools/build_libchiaki_visionos.sh   # devices only
#          VP_SKIP_IOS=1 ./Tools/build_libchiaki_visionos.sh   # visionOS only
# Needs:   Xcode 26+, Homebrew: cmake ninja protobuf python3
#
# LICENSE: the produced library is AGPL-3.0 (chiaki / chiaki-ng / Pylux), so
# Couchport as a whole is distributed under the AGPL-3.0 and its complete
# source (this repository at the release tag) must be published for every
# shipped build. This script also copies the license texts of everything it
# builds into Resources/Licenses so the About screen can show them.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/chiaki"
SRC="$WORK/Pylux"
OUT="$ROOT/Frameworks/VPChiaki.xcframework"
PYLUX_REPO="https://github.com/ForWard-Technologies-LLC/Pylux.git"
PYLUX_COMMIT="${PYLUX_COMMIT:-ca87a49a12bab071948f565ca53ffdad790775d3}"   # pinned 2026-10-19
TOOLCHAIN_URL="https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake"
DEPLOYMENT_TARGET="${VP_DEPLOYMENT_TARGET:-26.0}"

need() { command -v "$1" >/dev/null || { echo "Missing $1 (brew install $2)"; exit 1; }; }
need cmake cmake
need ninja ninja
need protoc protobuf
need python3 python3
python3 -c "import google.protobuf" 2>/dev/null || pip3 install --user --break-system-packages protobuf

mkdir -p "$WORK"

# 1. Source at a pinned commit.
if [ ! -d "$SRC/.git" ]; then
    git clone "$PYLUX_REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet --force "$PYLUX_COMMIT"
git -C "$SRC" submodule update --init --recursive \
    third-party/nanopb third-party/jerasure third-party/gf-complete third-party/curl

# 2. Patches (idempotent).
cp "$ROOT/ChiakiShim/vp_chiaki.c" "$SRC/lib/src/vp_chiaki.c"
cp "$ROOT/ChiakiShim/vp_chiaki.h" "$SRC/lib/include/vp_chiaki.h"
python3 - "$SRC" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1])

# a) compile the shim inside chiaki-lib
lib = src / "lib" / "CMakeLists.txt"
t = lib.read_text()
marker = "# VP_CHIAKI_SHIM"
if marker not in t:
    t += f"\n{marker}\ntarget_sources(chiaki-lib PRIVATE ${{CMAKE_CURRENT_SOURCE_DIR}}/src/vp_chiaki.c)\n"
    lib.write_text(t)

# b) the root forces a macOS deployment target (13.0) on every APPLE build,
#    which is not a valid visionOS version. Leave it to ios.toolchain.cmake.
root = src / "CMakeLists.txt"
t = root.read_text()
old = "if(APPLE)\n\tif(CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL \"arm64\")"
new = "if(APPLE AND NOT CHIAKI_ENABLE_IOS)\n\tif(CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL \"arm64\")"
if old in t:
    root.write_text(t.replace(old, new))
PY

# 3. Toolchain.
TOOLCHAIN="$WORK/ios.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || curl -sL -o "$TOOLCHAIN" "$TOOLCHAIN_URL"

build_platform() {
    local platform="$1" dir="$WORK/build-$1"
    echo "=== chiaki-lib for $platform ==="
    cmake -S "$SRC/ios" -B "$dir" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DPLATFORM="$platform" \
        -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_BITCODE=OFF \
        -DUSE_LIBIDN2=OFF \
        -DCURL_USE_LIBPSL=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    cmake --build "$dir" --config Release --target chiaki-lib
    # One fat static archive: chiaki + mbedtls + opus + json-c + miniupnpc + curl ...
    find "$dir" -name "*.a" ! -name "libvpchiaki.a" -print0 \
        | xargs -0 libtool -static -o "$dir/libvpchiaki.a"
    nm -g "$dir/libvpchiaki.a" 2>/dev/null | grep -q "_vp_session_create" \
        || { echo "ERROR: shim symbols missing from $dir/libvpchiaki.a"; exit 1; }
}

PLATFORMS=(VISIONOS)
[ "${VP_SKIP_SIM:-0}" = "1" ] || PLATFORMS+=(SIMULATOR_VISIONOS)
if [ "${VP_SKIP_IOS:-0}" != "1" ]; then
    PLATFORMS+=(OS64)
    [ "${VP_SKIP_SIM:-0}" = "1" ] || PLATFORMS+=(SIMULATORARM64)
fi
for p in "${PLATFORMS[@]}"; do build_platform "$p"; done

# 3b. License texts of everything linked, for the About screen.
LIC="$ROOT/Resources/Licenses"
mkdir -p "$LIC"
copy_license() { # name, search dir
    local f
    f="$(find "$2" -maxdepth 1 \( -iname 'COPYING*' -o -iname 'LICENSE*' \) -type f 2>/dev/null | head -1)"
    [ -n "$f" ] && cp "$f" "$LIC/LICENSE-$1.txt" || echo "warning: no license file for $1 in $2"
}
copy_license Pylux "$SRC/LICENSES"
copy_license nanopb "$SRC/third-party/nanopb"
copy_license Jerasure "$SRC/third-party/jerasure"
copy_license GF-Complete "$SRC/third-party/gf-complete"
copy_license curl "$SRC/third-party/curl"
for dep in mbedtls json-c miniupnp miniupnpc opus; do
    d="$(find "$WORK/build-${PLATFORMS[0]}" -maxdepth 4 -type d -iname "${dep}*" -path '*_deps*' ! -name '*-build' ! -name '*-subbuild' 2>/dev/null | head -1)"
    [ -n "$d" ] && copy_license "$dep" "$d" || echo "warning: $dep source not found for license copy"
done

# 4. Headers + module map.
HDR="$WORK/headers"
rm -rf "$HDR" && mkdir -p "$HDR"
cp "$ROOT/ChiakiShim/vp_chiaki.h" "$HDR/"
cat > "$HDR/module.modulemap" <<'MAP'
module VPChiaki {
    header "vp_chiaki.h"
    link "z"
    link "resolv"
    link framework "Security"
    link framework "SystemConfiguration"
    link framework "CFNetwork"
    export *
}
MAP

# 5. XCFramework.
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
ARGS=()
for p in "${PLATFORMS[@]}"; do
    ARGS+=(-library "$WORK/build-$p/libvpchiaki.a" -headers "$HDR")
done
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT"

echo ""
echo "Done: $OUT"
echo "Next: xcodegen generate && open PS5VisionCapture.xcodeproj"
