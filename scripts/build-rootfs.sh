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
qos_profile="${QOS_PROFILE:-server}"
repos_file="$root/config/apk/repositories"
base_pkgs_file="$root/config/apk/packages.base"
system_pkgs_file="$root/config/apk/packages.system"

[[ -f "$repos_file" ]] || die "missing repository manifest: $repos_file"
[[ -f "$base_pkgs_file" ]] || die "missing base package manifest: $base_pkgs_file"
[[ -f "$system_pkgs_file" ]] || die "missing system package manifest: $system_pkgs_file"

# Cache check. The rootfs is the slowest part of the build (apk fetches +
# extracts a lot). Reuse the previous rootfs if it was built for the same
# profile and the marker shows the apk stage completed. Force a rebuild
# with BUILD_FORCE_ROOTFS=1 or `make rootfs`.
cache_marker="$rootfs/.qos-cache-tag"
if [[ "${BUILD_FORCE_ROOTFS:-0}" != "1" && -f "$cache_marker" ]]; then
  cached_profile="$(awk -F= '$1=="profile"{print $2}' "$cache_marker" 2>/dev/null || true)"
  cached_status="$(awk -F= '$1=="status"{print $2}'  "$cache_marker" 2>/dev/null || true)"
  if [[ "$cached_profile" == "$qos_profile" && "$cached_status" == "ok" ]]; then
    manifest_add "rootfs: reused cached artifacts (profile=$qos_profile)"
    echo "rootfs: reusing cache ($rootfs, profile=$qos_profile)"
    # Layout may have changed even if packages didn't — re-apply it cheaply.
    "$script_dir/apply-rootfs-layout.sh" "$rootfs"
    exit 0
  fi
  echo "rootfs: cache miss (cached profile='$cached_profile' status='$cached_status' want='$qos_profile')"
fi

# Profile-specific extras come from config/qos.yaml via the manifest
# helper. The base+system files remain the source-of-truth for the
# `server` profile (and the manifest-diff check enforces they match
# qos.yaml). For non-server profiles, we layer the extra packages on top.
manifest_helper="$root/scripts/qos-manifest.sh"
profile_extras=()
if [[ "$qos_profile" != "server" && -x "$manifest_helper" ]]; then
  # Pull the full resolved set for the profile, then subtract base+system
  # so we add only the extras. Keeps order stable and dedupes.
  mapfile -t profile_full < <("$manifest_helper" packages --profile "$qos_profile" 2>/dev/null || true)
  mapfile -t profile_base < <(grep -vE '^\s*#|^\s*$' "$base_pkgs_file"; grep -vE '^\s*#|^\s*$' "$system_pkgs_file")
  declare -A _seen=()
  for p in "${profile_base[@]}"; do _seen[$p]=1; done
  for p in "${profile_full[@]}"; do
    [[ -z "${_seen[$p]:-}" ]] && profile_extras+=("$p") && _seen[$p]=1
  done
fi

chmod -R u+w "$rootfs" 2>/dev/null || true
rm -rf "$rootfs"
mkdir -p "$rootfs"
mkdir -p "$cache_root"

require_cmd curl bsdtar fakeroot sha256sum

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

pkg_args=("${base_pkgs[@]}" "${system_pkgs[@]}" "${profile_extras[@]}")
manifest_add "profile: $qos_profile"
if [[ "${#profile_extras[@]}" -gt 0 ]]; then
  manifest_add "profile-extras: ${profile_extras[*]}"
fi

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
bsdtar -xzf "$apk_tools_pkg" -C "$apk_static_dir" sbin/apk.static
install -m 0755 "$apk_static_dir/sbin/apk.static" "$apk_static_path"

mkdir -p "$rootfs/etc/apk/keys"
bsdtar -xzf "$alpine_keys_pkg" -C "$rootfs" etc/apk/keys
install -m 0644 "$repos_file" "$rootfs/etc/apk/repositories"

if [[ "${ROOTFS_SKIP_APK:-0}" == "1" ]]; then
  "$script_dir/apply-rootfs-layout.sh" "$rootfs"
  echo "rootfs staging complete (apk install skipped)"
  exit 0
fi

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
printf 'profile=%s\nstatus=ok\n' "$qos_profile" > "$cache_marker"

echo "rootfs staged under $rootfs"
