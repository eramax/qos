#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
rootfs="${ROOTFS_DIR:-$root/build/rootfs}"
repos_file="$root/config/apk/repositories"
base_pkgs_file="$root/config/apk/packages.base"
system_pkgs_file="$root/config/apk/packages.system"

[[ -f "$repos_file" ]] || die "missing repository manifest: $repos_file"
[[ -f "$base_pkgs_file" ]] || die "missing base package manifest: $base_pkgs_file"
[[ -f "$system_pkgs_file" ]] || die "missing system package manifest: $system_pkgs_file"

mkdir -p "$rootfs"

"$script_dir/apply-rootfs-layout.sh" "$rootfs"

if [[ "${ROOTFS_SKIP_APK:-0}" == "1" ]]; then
  echo "rootfs staging complete (apk install skipped)"
  exit 0
fi

require_cmd apk

mapfile -t repos < <(grep -vE '^\s*#|^\s*$' "$repos_file")
mapfile -t base_pkgs < <(grep -vE '^\s*#|^\s*$' "$base_pkgs_file")
mapfile -t system_pkgs < <(grep -vE '^\s*#|^\s*$' "$system_pkgs_file")

[[ "${#repos[@]}" -gt 0 ]] || die "no repositories listed in $repos_file"
[[ "${#base_pkgs[@]}" -gt 0 ]] || die "no base packages listed in $base_pkgs_file"
[[ "${#system_pkgs[@]}" -gt 0 ]] || die "no system packages listed in $system_pkgs_file"

repo_args=()
for repo in "${repos[@]}"; do
  repo_args+=("-X" "$repo")
done

pkg_args=("${base_pkgs[@]}" "${system_pkgs[@]}")

apk --root "$rootfs" --initdb --arch x86_64 "${repo_args[@]}" add --no-cache "${pkg_args[@]}"

"$script_dir/apply-rootfs-layout.sh" "$rootfs"

echo "rootfs staged under $rootfs"

