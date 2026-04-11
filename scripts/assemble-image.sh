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
layout_src="${IMAGE_LAYOUT:-$root/config/image/layout.json}"
slots_src="${IMAGE_SLOTS:-$root/config/image/slots.json}"
fstab_src="${IMAGE_FSTAB:-$root/config/image/fstab}"

[[ -d "$rootfs" ]] || die "missing rootfs staging dir: $rootfs"
[[ -f "$layout_src" ]] || die "missing image layout manifest: $layout_src"
[[ -f "$slots_src" ]] || die "missing slot manifest: $slots_src"
[[ -f "$fstab_src" ]] || die "missing fstab manifest: $fstab_src"

mkdir -p "$image_build_dir" "$image_output_dir"

cp "$layout_src" "$image_build_dir/layout.json"
cp "$slots_src" "$image_build_dir/slots.json"
cp "$fstab_src" "$image_build_dir/fstab"

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

die "real image assembly is not wired yet; set IMAGE_BUILD_MOCK=1 for scaffold/test mode"

