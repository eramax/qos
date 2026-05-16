#!/usr/bin/env bash
# Build ATL (Android Translation Layer) from source, producing artifacts for QOS.
#
# This script produces a tarball of runtime artifacts that the QOS ATL component
# places into the rootfs. It builds ATL from source and extracts runtime files
# from Alpine packages (art_standalone, bionic_translation, wolfssl-jni).
#
# Requirements:
#   - Alpine Linux edge (or any system with ICU 78, wolfssl-jni-dev, etc.)
#   - Build deps: meson, ninja, gcc, g++, openjdk8-jdk, python3, git, zip
#   - Alpine packages: gtk4-dev, webkit2gtk-6.0-dev, libportal-dev, vulkan-dev,
#     wayland-dev, wayland-protocols, wayland-client-dev, fontconfig-dev,
#     libavcodec-dev, libdrm-dev, libswscale-dev, gudev-dev, sqlite-dev,
#     alsa-lib-dev, glib-dev, libbsd-dev, liblz4-dev, etc.
#   - art_standalone, art_standalone-dev, bionic_translation, bionic_translation-dev
#   - wolfssl-jni, wolfssl-jni-dev
#
# Usage: sudo ./deps/atl-build.sh [--output-dir <path>]
#   Default output: deps/atl-artifacts/ (tarball + layout)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ATL_SRC="$ROOT/deps/android_translation_layer"
OUTPUT_DIR="${1:-$ROOT/deps/atl-artifacts}"
BUILD_DIR="/tmp/atl-build"
JOBS=$(nproc)

STAGING="$BUILD_DIR/staging"
mkdir -p "$STAGING" "$OUTPUT_DIR"

log() { echo "[*] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

[ -d "$ATL_SRC" ] || die "ATL source not found at $ATL_SRC. Clone it first."

log "=== ATL Build Script ==="
log "Source: $ATL_SRC"
log "Output: $OUTPUT_DIR"
log "Build dir: $BUILD_DIR"
log "Jobs: $JOBS"

# Step 1: Verify required packages are installed
log "Step 1: Verifying build dependencies..."
MISSING=""
for pkg in meson ninja gcc g++ openjdk8-jdk python3 git zip \
           gtk4-dev webkit2gtk-6.0-dev libportal-dev vulkan-dev \
           wayland-dev wayland-protocols fontconfig-dev \
           libavcodec-dev libdrm-dev libswscale-dev gudev-dev \
           sqlite-dev alsa-lib-dev glib-dev \
           libbsd-dev lz4-dev libunwind-dev libcap-dev libpng-dev \
           openssl-dev xz-dev zlib-dev expat-dev \
           bionic_translation bionic_translation-dev \
           wolfssl-jni wolfssl-jni-dev \
           art_standalone art_standalone-dev; do
    if ! apk info -e "$pkg" &>/dev/null; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -n "$MISSING" ]; then
    die "Missing packages:$MISSING. Install them first with: apk add$MISSING"
fi
log "All build dependencies satisfied."

# Step 2: Build ATL from source
log "Step 2: Building android-translation-layer..."
cd "$ATL_SRC"

# Clean previous build if exists
rm -rf build

meson setup build \
    --prefix=/usr \
    --libdir=lib \
    -Dbuildtype=release

ninja -C build -j"$JOBS"

log "Build successful. Installing to staging..."
DESTDIR="$STAGING" ninja -C build install

# Step 3: Collect runtime files from Alpine packages
log "Step 3: Collecting Alpine package runtime files..."

collect_pkg_files() {
    local pkg="$1" dest="$2"
    apk info -L "$pkg" 2>/dev/null | while read -r f; do
        local src="/$f"
        local tgt="$dest/$f"
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$tgt")"
            cp -a "$src" "$tgt"
        fi
    done
}

# art_standalone runtime libs
collect_pkg_files art_standalone "$STAGING"

# bionic_translation compatibility libs
collect_pkg_files bionic_translation "$STAGING"

# wolfssl-jni (needed by ART native libs)
collect_pkg_files wolfssl-jni "$STAGING"

# java-cacerts (needed by ART JVM)
collect_pkg_files java-cacerts "$STAGING"

# Step 4: Fix up paths — ensure all ATL libs are findable
log "Step 4: Fixing up artifact layout..."
# The android-translation-layer binary has RPATH: /usr/lib/art + /usr/lib/java/dex/android_translation_layer/natives
# So art libs need to be at /usr/lib/art/ and ATL natives at /usr/lib/java/dex/android_translation_layer/natives/
# Verify the layout
mkdir -p "$STAGING/usr/lib/art"
if [ -d "$STAGING/usr/lib/art" ]; then
    log "ART libs installed at usr/lib/art/"
    ls "$STAGING/usr/lib/art/" 2>/dev/null | head -5
fi

# Step 5: Package artifacts
log "Step 5: Packaging artifacts..."
cd "$STAGING"

TARBALL="$OUTPUT_DIR/atl-artifacts.tar.gz"
tar czf "$TARBALL" .
cp -a . "$OUTPUT_DIR/layout/"

log "=== Build Complete ==="
log "Tarball: $TARBALL"
log "Layout: $OUTPUT_DIR/layout/"
log ""
log "To deploy to QOS ATL component:"
log "  tar xzf $TARBALL -C components/atl/rootfs/"
log ""
log "Files included:"
find . -type f | sort
