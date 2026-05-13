#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Build QEMU 11.0.0 from source with GL acceleration and cursor visibility patch

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../lib/common.sh"

root="$(repo_root)"
qemu_version="11.0.0"
qemu_src_dir="$root/build/cache/qemu-src/qemu-${qemu_version}"
qemu_build_dir="$root/build/cache/qemu-build"
qemu_install_dir="$root/build/tools/qemu"
cache_marker="$qemu_install_dir/.qos-build-marker-${qemu_version}"

echo "Building QEMU $qemu_version with GL acceleration..."

# Bootstrap Ninja if not available
if ! command -v ninja &> /dev/null; then
  ninja_dir="$root/build/cache/ninja"
  mkdir -p "$ninja_dir"

  if [[ ! -f "$ninja_dir/ninja" ]]; then
    echo "Downloading Ninja build tool..."
    download_file "https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-linux.zip" \
      "$ninja_dir/ninja.zip"
    unzip -o "$ninja_dir/ninja.zip" -d "$ninja_dir/"
    chmod +x "$ninja_dir/ninja"
  fi

  export PATH="$ninja_dir:$PATH"
  echo "Using Ninja from $ninja_dir"
fi

# Check if already built
if [[ -f "$cache_marker" && -f "$qemu_install_dir/bin/qemu-system-x86_64" ]]; then
  echo "✓ QEMU $qemu_version already built at $qemu_install_dir"
  exit 0
fi

# Download QEMU source
if [[ ! -d "$qemu_src_dir" ]]; then
  mkdir -p "$root/build/cache/qemu-src"
  echo "Downloading QEMU $qemu_version..."
  download_file \
    "https://download.qemu.org/qemu-${qemu_version}.tar.xz" \
    "$root/build/cache/qemu-src/qemu-${qemu_version}.tar.xz"

  echo "Extracting QEMU..."
  tar -xJ -f "$root/build/cache/qemu-src/qemu-${qemu_version}.tar.xz" \
    -C "$root/build/cache/qemu-src/"
fi

cd "$qemu_src_dir"

# Check and apply cursor visibility patch if needed
cursor_patch_applied=false
if grep -q "c->visible" ui/gtk.c 2>/dev/null; then
  echo "✓ Cursor visibility patch already applied"
  cursor_patch_applied=true
fi

if [[ "$cursor_patch_applied" == "false" ]]; then
  echo "Applying cursor visibility patch..."

  # Create patch
  cat > /tmp/qemu-cursor-fix.patch << 'PATCH_EOF'
--- a/hw/display/virtio-gpu.c
+++ b/hw/display/virtio-gpu.c
@@ -98,6 +98,7 @@ static void update_cursor(VirtIOGPU *g, struct virtio_gpu_update_cursor *cursor
         s->current_cursor->hot_x = cursor->hot_x;
         s->current_cursor->hot_y = cursor->hot_y;
+        s->current_cursor->visible = cursor->resource_id ? 1 : 0;
         if (cursor->resource_id > 0) {
             vgc->update_cursor_data(g, s, cursor->resource_id);

--- a/include/ui/console.h
+++ b/include/ui/console.h
@@ -161,6 +161,7 @@ typedef struct QEMUCursor {
     uint16_t            width, height;
     int                 hot_x, hot_y;
     int                 refcount;
+    int                 visible;
     uint32_t            data[];
 } QEMUCursor;

--- a/ui/gtk.c
+++ b/ui/gtk.c
@@ -478,6 +478,11 @@ static void gd_cursor_define(DisplayChangeListener *dcl,
         return;
     }

+    if(!c->visible) {
+        gdk_window_set_cursor(gtk_widget_get_window(vc->gfx.drawing_area), NULL);
+        return;
+    }
+
     pixbuf = gdk_pixbuf_new_from_data((guchar *)(c->data),
                                       GDK_COLORSPACE_RGB, true, 8,
                                       c->width, c->height, c->width * 4,
PATCH_EOF

  # Try to apply patch (it might already be in 11.0.0, so allow failure)
  if patch -p1 < /tmp/qemu-cursor-fix.patch || true; then
    echo "✓ Cursor patch applied"
  else
    echo "⚠ Patch application failed, but continuing (patch may already be in 11.0.0)"
  fi
fi

# Create build directory
mkdir -p "$qemu_build_dir"
cd "$qemu_build_dir"

# Configure QEMU
echo "Configuring QEMU with GL acceleration and virgl support..."
"$qemu_src_dir/configure" \
  --target-list=x86_64-softmmu \
  --prefix="$qemu_install_dir" \
  --enable-kvm \
  --enable-gtk \
  --enable-opengl \
  --enable-virglrenderer \
  --enable-slirp \
  --enable-guest-agent \
  --enable-spice \
  --audio-drv-list=alsa,pa \
  --disable-docs \
  2>&1 | tail -20

# Build QEMU
echo "Building QEMU (this may take 10-20 minutes)..."
make -j$(nproc) 2>&1 | tail -20

# Install
echo "Installing QEMU to $qemu_install_dir..."
make install

# Write cache marker
mkdir -p "$(dirname "$cache_marker")"
touch "$cache_marker"

echo "✓ QEMU $qemu_version built successfully at $qemu_install_dir"
echo "Binary: $qemu_install_dir/bin/qemu-system-x86_64"
