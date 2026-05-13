#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/../../lib/common.sh"

root="$(repo_root)"
rootfs="${ROOTFS_DIR:-$root/build/rootfs}"
cache_root="${ROOTFS_CACHE_DIR:-$root/build/cache/rootfs}"
apk_arch="${APK_ARCH:-x86_64}"
qos_profile="${QOS_PROFILE:-server}"
repos_file="${APK_REPOSITORIES_FILE:-}"
resolved_pkgs_file="${APK_PACKAGES_FILE:-}"

[[ -n "$repos_file" ]] || die "APK_REPOSITORIES_FILE is required"
[[ -n "$resolved_pkgs_file" ]] || die "APK_PACKAGES_FILE is required"
[[ -f "$repos_file" ]] || die "missing repository manifest: $repos_file"
[[ -f "$resolved_pkgs_file" ]] || die "missing resolved package manifest: $resolved_pkgs_file"

# Cache check. The rootfs is the slowest part of the build (apk fetches +
# extracts a lot). Reuse the previous rootfs if it was built for the same
# profile and the marker shows the apk stage completed. Force a rebuild
# with BUILD_FORCE_ROOTFS=1 or `make rootfs`.
cache_marker="$rootfs/.qos-cache-tag"
if [[ "${BUILD_FORCE_ROOTFS:-0}" != "1" && -f "$cache_marker" ]]; then
  cached_profile="$(awk -F= '$1=="profile"{print $2}' "$cache_marker" 2>/dev/null || true)"
  cached_status="$(awk -F= '$1=="status"{print $2}'  "$cache_marker" 2>/dev/null || true)"
  cached_key="$(awk -F= '$1=="cache_key"{print $2}' "$cache_marker" 2>/dev/null || true)"
  if [[ "$cached_profile" == "$qos_profile" && "$cached_status" == "ok" && "$cached_key" == "${ROOTFS_CACHE_KEY:-}" ]]; then
    manifest_add "rootfs: reused cached artifacts (profile=$qos_profile)"
    echo "rootfs: reusing cache ($rootfs, profile=$qos_profile)"
    # Layout may have changed even if packages didn't — re-apply it cheaply.
    "$script_dir/apply-rootfs-layout.sh" "$rootfs"
    exit 0
  fi
  echo "rootfs: cache miss (cached profile='$cached_profile' status='$cached_status' key='$cached_key' want='$qos_profile' key='${ROOTFS_CACHE_KEY:-}')"
fi

chmod -R u+w "$rootfs" 2>/dev/null || true
rm -rf "$rootfs"
mkdir -p "$rootfs"
mkdir -p "$cache_root"

if [[ "${ROOTFS_SKIP_APK:-0}" == "1" ]]; then
  manifest_add "profile: $qos_profile"
  manifest_add "resolved-packages: $resolved_pkgs_file"
  manifest_add "rootfs: apk stage skipped"
  "$script_dir/apply-rootfs-layout.sh" "$rootfs"
  printf 'profile=%s\nstatus=ok\ncache_key=%s\n' "$qos_profile" "${ROOTFS_CACHE_KEY:-}" > "$cache_marker"
  chmod 0444 "$cache_marker"
  echo "rootfs staging complete (apk install skipped)"
  exit 0
fi

require_cmd curl bsdtar fakeroot sha256sum

mapfile -t repos < <(grep -vE '^\s*#|^\s*$' "$repos_file")
mapfile -t pkg_args < <(grep -vE '^\s*#|^\s*$' "$resolved_pkgs_file")

[[ "${#repos[@]}" -gt 0 ]] || die "no repositories listed in $repos_file"
[[ "${#pkg_args[@]}" -gt 0 ]] || die "no packages resolved for profile $qos_profile"

repo_args=()
for repo in "${repos[@]}"; do
  repo_args+=("-X" "$repo")
done

manifest_add "profile: $qos_profile"
manifest_add "resolved-packages: $resolved_pkgs_file"

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
  if [[ ! -f "$index_tar" ]]; then
    download_file "$index_url" "$index_tar"
  fi
  bsdtar -xOf "$index_tar" APKINDEX > "$index_txt"
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
  if [[ ! -f "$dest" ]]; then
    download_file "$url" "$dest"
  fi
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

manifest_add "command: builder/pipeline/01-rootfs/build-rootfs.sh rootfs=$rootfs"
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
bsdtar -xzf "$apk_tools_pkg" -C "$apk_static_dir" sbin/apk.static
install -m 0755 "$apk_static_dir/sbin/apk.static" "$apk_static_path"

mkdir -p "$rootfs/etc/apk/keys"
bsdtar -xzf "$alpine_keys_pkg" -C "$rootfs" etc/apk/keys
install -m 0644 "$repos_file" "$rootfs/etc/apk/repositories"

# Alpine 3.23's apk-tools requires explicit usermode initdb when staging a rootfs
# as a non-root user. This keeps the build working under the repo's non-root flow.
fakeroot -- "$apk_static_path" --root "$rootfs" --initdb --usermode --arch "$apk_arch" "${repo_args[@]}" --keys-dir "$rootfs/etc/apk/keys" add --no-cache --no-scripts "${pkg_args[@]}"

"$script_dir/apply-rootfs-layout.sh" "$rootfs"

# Install kernel modules into the rootfs. The kernel build stages them
# under build/kernel/modules/lib/modules/<version>/.
kernel_build_dir="${KERNEL_BUILD_DIR:-$root/build/kernel}"
modules_stage="$kernel_build_dir/modules"
if [[ -d "$modules_stage/lib/modules" ]]; then
  kver="$(ls "$modules_stage/lib/modules/")"
  if [[ -n "$kver" ]]; then
    chmod -R u+w "$rootfs/lib" 2>/dev/null || true
    mkdir -p "$rootfs/lib/modules"
    chmod -R u+w "$rootfs/lib/modules" 2>/dev/null || true
    cp -a "$modules_stage/lib/modules/$kver" "$rootfs/lib/modules/$kver"
    # Remove the build and source symlinks — they point at the host tree.
    rm -f "$rootfs/lib/modules/$kver/build" "$rootfs/lib/modules/$kver/source"
    # Generate modules.dep so modprobe works without depmod at runtime.
    if command -v depmod >/dev/null 2>&1; then
      depmod -b "$rootfs" "$kver" 2>/dev/null || true
    elif command -v busybox >/dev/null 2>&1; then
      busybox depmod -b "$rootfs" "$kver" 2>/dev/null || true
    fi
    echo "kernel modules installed: $kver"
  fi
fi

# Stamp the cache marker only after a successful build. cleanup hooks in
# build.sh use the marker to decide whether to wipe the rootfs between
# builds.
printf 'profile=%s\nstatus=ok\ncache_key=%s\n' "$qos_profile" "${ROOTFS_CACHE_KEY:-}" > "$cache_marker"
chmod 0444 "$cache_marker"

echo "rootfs staged under $rootfs"
