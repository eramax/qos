#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/common.sh"

root="$(repo_root)"
boot_dir="${BOOT_STAGE_DIR:-$root/build/boot}"
iso_output_dir="${ISO_OUTPUT_DIR:-$root/dist}"
iso_name="${ISO_NAME:-qos-x86_64.iso}"
limine_cache_dir="${LIMINE_CACHE_DIR:-$root/build/cache/limine}"

[[ -d "$boot_dir" ]] || die "missing boot staging dir: $boot_dir"
[[ -f "$boot_dir/vmlinuz" ]] || die "missing kernel: $boot_dir/vmlinuz"
[[ -f "$boot_dir/initramfs.img" ]] || die "missing initramfs: $boot_dir/initramfs.img"

mkdir -p "$iso_output_dir" "$limine_cache_dir"

if [[ "${ISO_BUILD_MOCK:-0}" == "1" ]]; then
  printf '%s\n' "mock ISO image" > "$iso_output_dir/$iso_name"
  echo "ISO build skipped (mock mode)"
  exit 0
fi

require_cmd xorriso

# Get Limine EFI binaries
limine_src="$limine_cache_dir/limine"
if [[ ! -d "$limine_src/.git" ]]; then
  branch="$(tr -d '[:space:]' < "$root/config/limine/branch")"
  echo "Cloning Limine for EFI binaries..."
  git clone --depth 1 --branch "$branch" https://github.com/limine-bootloader/limine.git "$limine_src" >/dev/null 2>&1
fi

# Create ISO root structure
iso_root="$(mktemp -d)"
trap 'rm -rf "$iso_root"' EXIT

echo "Setting up ISO structure..."
mkdir -p "$iso_root/EFI/BOOT"
mkdir -p "$iso_root/boot"
mkdir -p "$iso_root/limine"

# Copy Limine bootloader
cp "$limine_src/BOOTX64.EFI" "$iso_root/EFI/BOOT/BOOTX64.EFI"

# Copy Limine config
cat > "$iso_root/limine.conf" <<'EOF'
timeout: 0
verbose: yes

/QOS Live CD
    protocol: linux
    kernel_path: boot():/boot/vmlinuz
    module_path: boot():/boot/initramfs.img
    cmdline: root=LABEL=qos-root-a rootfstype=ext4 rootwait ro console=ttyS0,115200n8 earlycon=uart,io,0x3f8,115200n8 loglevel=7 net.ifnames=0 biosdevname=0
EOF

# Copy kernel and initramfs
cp "$boot_dir/vmlinuz" "$iso_root/boot/vmlinuz"
cp "$boot_dir/initramfs.img" "$iso_root/boot/initramfs.img"

# Copy limine files
cp "$limine_src/BOOTX64.EFI" "$iso_root/limine/"

echo "Creating bootable ISO..."
xorriso -as mkisofs \
  -o "$iso_output_dir/$iso_name" \
  -b limine/BOOTX64.EFI \
  --efi-boot limine/BOOTX64.EFI \
  -no-emul-boot \
  -V "QOS_LIVE" \
  -input-charset utf-8 \
  "$iso_root" >/dev/null 2>&1 || {
    echo "Creating basic ISO without El Torito..."
    xorriso -as mkisofs \
      -o "$iso_output_dir/$iso_name" \
      -V "QOS_LIVE" \
      -input-charset utf-8 \
      "$iso_root"
  }

iso_size="$(du -sh "$iso_output_dir/$iso_name" | awk '{print $1}')"
echo ""
echo "✅ ISO build complete: $iso_output_dir/$iso_name ($iso_size)"
echo ""
echo "Boot with: make boot"
