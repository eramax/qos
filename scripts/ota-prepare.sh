#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
slots_file="${OTA_SLOTS_FILE:-$root/config/image/slots.json}"
state_dir="${OTA_STATE_DIR:-$root/build/ota}"
image_path="${OTA_IMAGE:-${1:-}}"

[[ -f "$slots_file" ]] || die "missing slot manifest: $slots_file"
[[ -n "$image_path" ]] || die "usage: $0 <image-path>"
[[ -f "$image_path" ]] || die "missing image artifact: $image_path"
[[ -s "$image_path" ]] || die "image artifact is empty: $image_path"

require_cmd jq

active_slot="$(jq -r '.active' "$slots_file")"
inactive_slot="$(jq -r '.inactive' "$slots_file")"
fallback_slot="$(jq -r '.fallback' "$slots_file")"

mkdir -p "$state_dir/staging/$inactive_slot"
staged_image="$state_dir/staging/$inactive_slot/image.raw"
cp "$image_path" "$staged_image"

mkdir -p "$state_dir"
jq -n \
  --arg active_slot "$active_slot" \
  --arg previous_slot "$active_slot" \
  --arg pending_slot "$inactive_slot" \
  --arg fallback_slot "$fallback_slot" \
  --arg staged_image "$staged_image" \
  '{
    active_slot: $active_slot,
    previous_slot: $previous_slot,
    pending_slot: $pending_slot,
    fallback_slot: $fallback_slot,
    staged_image: $staged_image,
    boot_verified: false
  }' > "$state_dir/state.json"

echo "$staged_image"

