#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
kernel_config="${KERNEL_CONFIG:-$root/config/kernel/x86_64.config}"
kernel_build_dir="${KERNEL_BUILD_DIR:-$root/build/kernel}"

[[ -f "$kernel_config" ]] || die "missing kernel config: $kernel_config"
ensure_dir "$kernel_build_dir"

cp "$kernel_config" "$kernel_build_dir/kernel.config"

if [[ "${KERNEL_BUILD_MOCK:-0}" == "1" ]]; then
  printf '%s\n' "mock kernel image" > "$kernel_build_dir/vmlinuz"
  printf '%s\n' "mock kernel symbol map" > "$kernel_build_dir/System.map"
  echo "kernel build skipped (mock mode)"
  exit 0
fi

if [[ -z "${KERNEL_SRC:-}" ]]; then
  die "KERNEL_SRC is required for a real kernel build (set KERNEL_BUILD_MOCK=1 for scaffold/test mode)"
fi

require_cmd make

die "real kernel compilation is not wired yet; set KERNEL_BUILD_MOCK=1 for scaffold/test mode"

