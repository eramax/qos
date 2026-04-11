#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
rootfs="${ROOTFS_DIR:-$root/build/rootfs}"
cache_root="${ROOTFS_CACHE_DIR:-$root/build/cache/rootfs}"
apk_arch="${APK_ARCH:-x86_64}"
repos_file="$root/config/apk/repositories"
base_pkgs_file="$root/config/apk/packages.base"
system_pkgs_file="$root/config/apk/packages.system"

[[ -f "$repos_file" ]] || die "missing repository manifest: $repos_file"
[[ -f "$base_pkgs_file" ]] || die "missing base package manifest: $base_pkgs_file"
[[ -f "$system_pkgs_file" ]] || die "missing system package manifest: $system_pkgs_file"

chmod -R u+w "$rootfs" 2>/dev/null || true
rm -rf "$rootfs"
mkdir -p "$rootfs"
mkdir -p "$cache_root"

"$script_dir/apply-rootfs-layout.sh" "$rootfs"
chmod -R u+w "$rootfs"

if [[ "${ROOTFS_SKIP_APK:-0}" == "1" ]]; then
  echo "rootfs staging complete (apk install skipped)"
  exit 0
fi

require_cmd curl tar sha256sum

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

repo_index_url() {
  local repo="${1%/}"
  echo "$repo/$apk_arch/APKINDEX.tar.gz"
}

pkg_version_from_repo() {
  local repo="$1"
  local pkg="$2"
  local index_url
  local index_tar
  local index_txt
  index_url="$(repo_index_url "$repo")"
  index_tar="$cache_root/$(basename "$repo").APKINDEX.tar.gz"
  index_txt="$cache_root/$(basename "$repo").APKINDEX"
  download_file "$index_url" "$index_tar"
  tar -xOf "$index_tar" APKINDEX > "$index_txt"
  awk -v pkg="$pkg" '
    $0 == "P:" pkg { hit=1; next }
    hit && $0 ~ /^V:/ { sub(/^V:/, "", $0); print; exit }
  ' "$index_txt"
}

pkg_download() {
  local repo="$1"
  local pkg="$2"
  local version="$3"
  local url
  local dest
  url="${repo%/}/$apk_arch/${pkg}-${version}.apk"
  dest="$cache_root/${pkg}-${version}.apk"
  download_file "$url" "$dest"
  local sha
  sha="$(sha256sum "$dest" | awk '{print $1}')"
  manifest_add "download: $url sha256=$sha"
  echo "$dest"
}

bootstrap_repo="${repos[0]}"
apk_tools_version="$(pkg_version_from_repo "$bootstrap_repo" apk-tools-static)"
alpine_keys_version="$(pkg_version_from_repo "$bootstrap_repo" alpine-keys)"

[[ -n "$apk_tools_version" ]] || die "unable to determine apk-tools-static version"
[[ -n "$alpine_keys_version" ]] || die "unable to determine alpine-keys version"

manifest_add "command: scripts/build-rootfs.sh rootfs=$rootfs"
manifest_add "source: alpine-repo ${bootstrap_repo%/}"
manifest_add "package: apk-tools-static $apk_tools_version"
manifest_add "package: alpine-keys $alpine_keys_version"
for pkg in "${pkg_args[@]}"; do
  manifest_add "package: $pkg"
done

apk_tools_pkg="$(pkg_download "$bootstrap_repo" apk-tools-static "$apk_tools_version")"
alpine_keys_pkg="$(pkg_download "$bootstrap_repo" alpine-keys "$alpine_keys_version")"

tool_root="$cache_root/tooling"
apk_static_dir="$tool_root/apk-static"
apk_static_path="$tool_root/apk.static"
mkdir -p "$apk_static_dir"
tar -xzf "$apk_tools_pkg" -C "$apk_static_dir" sbin/apk.static
install -m 0755 "$apk_static_dir/sbin/apk.static" "$apk_static_path"

mkdir -p "$rootfs/etc/apk/keys"
tar -xzf "$alpine_keys_pkg" -C "$rootfs" etc/apk/keys

"$apk_static_path" --root "$rootfs" --initdb --arch "$apk_arch" "${repo_args[@]}" --keys-dir "$rootfs/etc/apk/keys" add --no-cache --no-scripts "${pkg_args[@]}"

"$script_dir/apply-rootfs-layout.sh" "$rootfs"

echo "rootfs staged under $rootfs"
