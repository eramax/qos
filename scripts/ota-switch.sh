#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
state_dir="${OTA_STATE_DIR:-$root/build/ota}"
state_file="$state_dir/state.json"

[[ -f "$state_file" ]] || die "missing OTA state file: $state_file"
require_cmd jq

active_slot="$(jq -r '.active_slot' "$state_file")"
pending_slot="$(jq -r '.pending_slot' "$state_file")"
[[ "$pending_slot" != "null" && -n "$pending_slot" ]] || die "no pending slot to switch to"

jq \
  --arg active_slot "$pending_slot" \
  --arg previous_slot "$active_slot" \
  --argjson boot_verified false \
  '.active_slot = $active_slot
   | .previous_slot = $previous_slot
   | .pending_slot = null
   | .boot_verified = $boot_verified' \
  "$state_file" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

echo "$pending_slot"

