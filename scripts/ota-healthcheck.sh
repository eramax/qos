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

if [[ "${OTA_BOOT_OK:-1}" == "1" && "${OTA_NETWORK_OK:-1}" == "1" && "${OTA_SERVICE_OK:-1}" == "1" ]]; then
  jq '.boot_verified = true' "$state_file" > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"
  echo "ok"
  exit 0
fi

if [[ "${OTA_AUTOROLLBACK:-0}" == "1" ]]; then
  OTA_STATE_DIR="$state_dir" "$script_dir/ota-rollback.sh" >/dev/null
fi

die "healthcheck failed"

