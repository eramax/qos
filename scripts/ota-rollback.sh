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

current_slot="$(jq -r '.active_slot' "$state_file")"
previous_slot="$(jq -r '.previous_slot' "$state_file")"
[[ "$previous_slot" != "null" && -n "$previous_slot" ]] || die "no previous slot to roll back to"

jq \
  --arg active_slot "$previous_slot" \
  --arg previous_slot "$current_slot" \
  --argjson boot_verified false \
  '.active_slot = $active_slot
   | .previous_slot = $previous_slot
   | .pending_slot = null
   | .boot_verified = $boot_verified' \
  "$state_file" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

echo "$previous_slot"

