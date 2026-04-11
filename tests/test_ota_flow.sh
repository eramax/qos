#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

for script in scripts/ota-prepare.sh scripts/ota-switch.sh scripts/ota-rollback.sh scripts/ota-healthcheck.sh; do
  [[ -x "$repo_root/$script" ]] || die "missing $script"
done

command -v jq >/dev/null 2>&1 || die "jq is required for the OTA flow test"

stage_base="$(mktemp -d "$repo_root/build/task6.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

ota_state_dir="$stage_base/ota"
image_path="$stage_base/update.raw"
var_dir="$stage_base/var"

truncate -s 1M "$image_path"
mkdir -p "$var_dir/lib/qos"
printf '%s\n' "preserve-me" > "$var_dir/lib/qos/data.txt"

staged_image="$(OTA_STATE_DIR="$ota_state_dir" OTA_IMAGE="$image_path" "$repo_root/scripts/ota-prepare.sh")"
[[ -f "$staged_image" ]] || die "staged image was not created"
[[ "$(jq -r '.pending_slot' "$ota_state_dir/state.json")" == "B" ]] || die "inactive slot was not selected for update"
[[ "$(jq -r '.active_slot' "$ota_state_dir/state.json")" == "A" ]] || die "unexpected active slot before switch"

OTA_STATE_DIR="$ota_state_dir" "$repo_root/scripts/ota-switch.sh" >/dev/null
[[ "$(jq -r '.active_slot' "$ota_state_dir/state.json")" == "B" ]] || die "slot promotion did not occur"
[[ "$(jq -r '.previous_slot' "$ota_state_dir/state.json")" == "A" ]] || die "previous slot not recorded"

OTA_STATE_DIR="$ota_state_dir" OTA_BOOT_OK=1 OTA_NETWORK_OK=1 OTA_SERVICE_OK=1 "$repo_root/scripts/ota-healthcheck.sh" >/dev/null
[[ "$(jq -r '.boot_verified' "$ota_state_dir/state.json")" == "true" ]] || die "boot verification marker not recorded"

set +e
OTA_STATE_DIR="$ota_state_dir" OTA_BOOT_OK=0 OTA_NETWORK_OK=1 OTA_SERVICE_OK=1 OTA_AUTOROLLBACK=1 \
  "$repo_root/scripts/ota-healthcheck.sh" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || die "healthcheck should fail when boot check fails"

[[ "$(jq -r '.active_slot' "$ota_state_dir/state.json")" == "A" ]] || die "rollback did not restore the fallback slot"
[[ -f "$var_dir/lib/qos/data.txt" ]] || die "mutable /var data was lost across slot changes"
[[ "$(cat "$var_dir/lib/qos/data.txt")" == "preserve-me" ]] || die "mutable /var data was modified"

echo "ok"
