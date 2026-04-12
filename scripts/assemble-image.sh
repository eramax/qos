#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
rootfs="${ROOTFS_DIR:-$root/build/rootfs}"
image_build_dir="${IMAGE_BUILD_DIR:-$root/build/image}"
image_output_dir="${IMAGE_OUTPUT_DIR:-$root/dist}"
image_name="${IMAGE_NAME:-qos-x86_64.raw}"
boot_stage_dir="${BOOT_STAGE_DIR:-$root/build/boot}"
layout_src="${IMAGE_LAYOUT:-$root/config/image/layout.json}"
slots_src="${IMAGE_SLOTS:-$root/config/image/slots.json}"
fstab_src="${IMAGE_FSTAB:-$root/config/image/fstab}"
state_template="${STATE_TEMPLATE:-$root/config/image/slots.json}"
efi_size="${EFI_PART_SIZE:-}"
root_a_size="${ROOT_A_SIZE:-}"
root_b_size="${ROOT_B_SIZE:-}"
state_size="${STATE_PART_SIZE:-}"

[[ -d "$rootfs" ]] || die "missing rootfs staging dir: $rootfs"
[[ -f "$layout_src" ]] || die "missing image layout manifest: $layout_src"
[[ -f "$slots_src" ]] || die "missing slot manifest: $slots_src"
[[ -f "$fstab_src" ]] || die "missing fstab manifest: $fstab_src"
mkdir -p "$image_build_dir" "$image_output_dir"

cp "$layout_src" "$image_build_dir/layout.json"
cp "$slots_src" "$image_build_dir/slots.json"
cp "$fstab_src" "$image_build_dir/fstab"
chmod -R u+w "$image_build_dir" 2>/dev/null || true
rm -rf "$image_build_dir/boot"
if [[ -d "$boot_stage_dir" ]]; then
  cp -a "$boot_stage_dir" "$image_build_dir/boot"
else
  mkdir -p "$image_build_dir/boot"
fi

inactive_slot="$(grep -o '"inactive"[[:space:]]*:[[:space:]]*"[^"]\+"' "$slots_src" | head -n1 | sed 's/.*"inactive"[[:space:]]*:[[:space:]]*"\([^"]\+\)"/\1/')"
[[ -n "$inactive_slot" ]] || die "unable to parse inactive slot from $slots_src"

slot_root="$image_build_dir/slots/$inactive_slot/rootfs"
mkdir -p "$(dirname "$slot_root")"

if [[ "${IMAGE_BUILD_MOCK:-0}" == "1" ]]; then
  rm -rf "$slot_root"
  cp -a "$rootfs" "$slot_root"
  truncate -s "${IMAGE_SIZE:-64M}" "$image_output_dir/$image_name"
  printf '%s\n' "mock raw disk image" > "$image_build_dir/image.manifest"
  echo "image assembly skipped (mock mode)"
  exit 0
fi

require_cmd jq sgdisk mkfs.ext4 mkfs.vfat mcopy mmd dd truncate sha256sum

size_to_bytes() {
  local value="${1:-}"
  case "$value" in
    *G) echo $(( ${value%G} * 1024 * 1024 * 1024 )) ;;
    *M) echo $(( ${value%M} * 1024 * 1024 )) ;;
    *K) echo $(( ${value%K} * 1024 )) ;;
    *) echo "$value" ;;
  esac
}

part_size_from_layout() {
  local name="$1"
  jq -r --arg name "$name" '.partitions[] | select(.name == $name) | .size' "$layout_src"
}

efi_size="${efi_size:-$(part_size_from_layout efi)}"
root_a_size="${root_a_size:-$(part_size_from_layout root-a)}"
root_b_size="${root_b_size:-$(part_size_from_layout root-b)}"
state_size="${state_size:-$(part_size_from_layout state)}"

[[ -n "$efi_size" && -n "$root_a_size" && -n "$root_b_size" && -n "$state_size" ]] || die "missing partition size metadata"

manifest_add "command: scripts/assemble-image.sh image=$image_name"
manifest_add "partition: efi size=$efi_size"
manifest_add "partition: root-a size=$root_a_size"
manifest_add "partition: root-b size=$root_b_size"
manifest_add "partition: state size=$state_size"

partitions_dir="$image_build_dir/partitions"
mkdir -p "$partitions_dir"

efi_img="$partitions_dir/efi.img"
root_a_img="$partitions_dir/root-a.img"
root_b_img="$partitions_dir/root-b.img"
state_img="$partitions_dir/state.img"

rm -f "$efi_img" "$root_a_img" "$root_b_img" "$state_img"
truncate -s "$efi_size" "$efi_img"
truncate -s "$root_a_size" "$root_a_img"
truncate -s "$root_b_size" "$root_b_img"
truncate -s "$state_size" "$state_img"

mkfs.vfat -F 32 -n QOS-EFI "$efi_img" >/dev/null
mmd -i "$efi_img" ::/EFI ::/EFI/BOOT
printf 'map -r\r\nfs0:\\EFI\\BOOT\\BOOTX64.EFI\r\n' > "$partitions_dir/startup.nsh"
mcopy -i "$efi_img" "$boot_stage_dir/limine.conf" ::/limine.conf
mcopy -i "$efi_img" "$boot_stage_dir/EFI/BOOT/limine.conf" ::/EFI/BOOT/limine.conf
mcopy -i "$efi_img" "$boot_stage_dir/vmlinuz" ::/vmlinuz
mcopy -i "$efi_img" "$boot_stage_dir/initramfs.img" ::/initramfs.img
mcopy -i "$efi_img" "$boot_stage_dir/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$efi_img" "$partitions_dir/startup.nsh" ::/startup.nsh
if [[ -f "$boot_stage_dir/EFI/BOOT/BOOTIA32.EFI" ]]; then
  mcopy -i "$efi_img" "$boot_stage_dir/EFI/BOOT/BOOTIA32.EFI" ::/EFI/BOOT/BOOTIA32.EFI
fi

mkfs.ext4 -F -L qos-root-a -d "$rootfs" "$root_a_img" >/dev/null
mkfs.ext4 -F -L qos-root-b -d "$rootfs" "$root_b_img" >/dev/null

state_root="$partitions_dir/state-root"
rm -rf "$state_root"
mkdir -p "$state_root/var/lib/qos" "$state_root/var/log" "$state_root/etc"
mkdir -p "$state_root/overlay/upper" "$state_root/overlay/work"
jq -n \
  --slurpfile slots "$slots_src" \
  '{active: $slots[0].active, inactive: $slots[0].inactive, fallback: $slots[0].fallback}' \
  > "$state_root/var/lib/qos/slot-state.json"
mkfs.ext4 -F -L qos-state -d "$state_root" "$state_img" >/dev/null

slot_root_dir="$image_build_dir/slots/$inactive_slot/rootfs"
chmod -R u+w "$image_build_dir/slots" 2>/dev/null || true
rm -rf "$slot_root_dir"
cp -a "$rootfs" "$slot_root_dir"

raw_image="$image_output_dir/$image_name"
raw_size="${IMAGE_SIZE:-$(jq -r '.image_size // "512M"' "$layout_src")}"
rm -f "$raw_image"
truncate -s "$raw_size" "$raw_image"

sgdisk -o "$raw_image" >/dev/null
sgdisk -n 1:2048:+$efi_size -t 1:ef00 -c 1:EFI "$raw_image" >/dev/null
sgdisk -n 2:0:+$root_a_size -t 2:8300 -c 2:root-a "$raw_image" >/dev/null
sgdisk -n 3:0:+$root_b_size -t 3:8300 -c 3:root-b "$raw_image" >/dev/null
sgdisk -n 4:0:+$state_size -t 4:8300 -c 4:state "$raw_image" >/dev/null

get_start_sector() {
  local part="$1"
  sgdisk -i "$part" "$raw_image" | awk -F': ' '/First sector/ {sub(/ .*/, "", $2); print $2; exit}'
}

write_partition() {
  local image_file="$1"
  local part="$2"
  local start_sector
  start_sector="$(get_start_sector "$part")"
  [[ -n "$start_sector" ]] || die "unable to determine start sector for partition $part"
  dd if="$image_file" of="$raw_image" bs=512 seek="$start_sector" conv=notrunc status=none
}

write_partition "$efi_img" 1
write_partition "$root_a_img" 2
write_partition "$root_b_img" 3
write_partition "$state_img" 4

manifest_add "image: $raw_image sha256=$(sha256sum "$raw_image" | awk '{print $1}')"
printf '%s\n' "real raw disk image" > "$image_build_dir/image.manifest"

echo "image assembly complete: $raw_image"
