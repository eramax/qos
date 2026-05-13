#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
kernel_config="${KERNEL_CONFIG:-$root/config/kernel/x86_64.config}"
kernel_build_dir="${KERNEL_BUILD_DIR:-$root/build/kernel}"
kernel_version_file="${KERNEL_VERSION_FILE:-$root/config/kernel/version}"
# Cache hit: bzImage exists and config hasn't changed since the last
# successful build.  Reuse the artifacts and skip the full build.
kernel_out="$kernel_build_dir/build"
kernel_out_cache="$kernel_out/.qos-kernel-cache-tag"
kernel_config_hash="$(sha256sum "$kernel_config" | awk '{print $1}')"
if [[ -f "$kernel_out/arch/x86/boot/bzImage" && -f "$kernel_out_cache" ]]; then
  cached_hash="$(awk -F= '$1=="config_hash"{print $2}' "$kernel_out_cache" 2>/dev/null || true)"
  if [[ "$cached_hash" == "$kernel_config_hash" ]]; then
    manifest_add "kernel: reused cached build (config unchanged)"
    echo "kernel: reusing cache ($kernel_out)"
    cp "$kernel_out/arch/x86/boot/bzImage" "$kernel_build_dir/vmlinuz"
    cp "$kernel_out/System.map" "$kernel_build_dir/System.map"
    if [[ ! -d "$kernel_build_dir/modules/lib/modules" ]]; then
      echo "kernel: WARNING: modules missing from cache, forcing rebuild"
    else
      echo "kernel build complete (cached): $kernel_build_dir/vmlinuz"
      exit 0
    fi
  else
    echo "kernel: config changed, rebuilding ($cached_hash -> $kernel_config_hash)"
  fi
fi

cache_root="${KERNEL_CACHE_DIR:-$root/build/cache/kernel}"
kernel_version="${KERNEL_VERSION:-}"
tool_root="$cache_root/tooling"
tool_prefix="$tool_root/prefix"

[[ -f "$kernel_config" ]] || die "missing kernel config: $kernel_config"
ensure_dir "$kernel_build_dir"
mkdir -p "$cache_root"

cp "$kernel_config" "$kernel_build_dir/kernel.config"

if [[ "${KERNEL_BUILD_MOCK:-0}" == "1" ]]; then
  printf '%s\n' "mock kernel image" > "$kernel_build_dir/vmlinuz"
  printf '%s\n' "mock kernel symbol map" > "$kernel_build_dir/System.map"
  echo "kernel build skipped (mock mode)"
  exit 0
fi

require_cmd curl tar sha256sum make bc perl
mkdir -p "$tool_root"

bootstrap_gnu_tool() {
  local name="$1"
  local version="$2"
  local url="$3"
  local configure_args="${4:-}"
  local src_tar="$tool_root/$name-$version.tar.xz"
  local src_dir="$tool_root/src/$name-$version"
  local build_dir="$tool_root/build/$name-$version"

  if command -v "$name" >/dev/null 2>&1; then
    return 0
  fi

  manifest_add "source: $name $url"
  if [[ ! -f "$src_tar" ]]; then
    download_file "$url" "$src_tar"
  fi
  manifest_add "download: $url sha256=$(sha256sum "$src_tar" | awk '{print $1}')"

  if [[ ! -d "$src_dir" ]]; then
    mkdir -p "$tool_root/src"
    tar -xf "$src_tar" -C "$tool_root/src"
  fi

  mkdir -p "$build_dir"
  (
    cd "$src_dir"
    if [[ ! -x configure ]]; then
      die "missing configure script in $src_dir"
    fi
    CFLAGS="${BUILD_TOOL_CFLAGS:--std=gnu11}" \
    PATH="$tool_prefix/bin:$PATH" ./configure --prefix="$tool_prefix" --disable-nls $configure_args >/dev/null
    CFLAGS="${BUILD_TOOL_CFLAGS:--std=gnu11}" \
    PATH="$tool_prefix/bin:$PATH" make -j"${BUILD_TOOL_JOBS:-1}" >/dev/null
    CFLAGS="${BUILD_TOOL_CFLAGS:--std=gnu11}" \
    PATH="$tool_prefix/bin:$PATH" make install >/dev/null
  )
}

bootstrap_gnu_tool m4 1.4.20 https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz
bootstrap_gnu_tool flex 2.6.4 https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz
bootstrap_gnu_tool bison 3.8.2 https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz

if [[ -z "$kernel_version" ]]; then
  [[ -f "$kernel_version_file" ]] || die "missing kernel version file: $kernel_version_file"
  kernel_version="$(tr -d '[:space:]' < "$kernel_version_file")"
fi
[[ -n "$kernel_version" ]] || die "kernel version is empty"

manifest_add "command: scripts/build-kernel.sh version=$kernel_version"

# Determine source: git tag (RC) or tarball (stable)
kernel_src="$cache_root/linux-$kernel_version"

if [[ "$kernel_version" == *-rc* ]]; then
  # RC kernels are only available via git
  manifest_add "source: kernel git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git#$kernel_version"
  
  require_cmd git
  mkdir -p "$cache_root"
  
  if [[ ! -d "$cache_root/linux-torvalds/.git" ]]; then
    echo "Cloning Linux kernel git repository (this may take a while)..."
    git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$cache_root/linux-torvalds"
  fi
  
  cd "$cache_root/linux-torvalds"
  echo "Fetching tag $kernel_version..."
  git fetch --depth 1 origin tag "$kernel_version" 2>/dev/null || git fetch --depth 1 origin tag "v$kernel_version" 2>/dev/null || true
  git checkout "$kernel_version" 2>/dev/null || git checkout "v$kernel_version" 2>/dev/null || true
  cd - >/dev/null
  
  kernel_src="$cache_root/linux-torvalds"
else
  # Stable kernels from tarball
  major="${kernel_version%%.*}"
  kernel_url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-$kernel_version.tar.xz"
  kernel_tar="$cache_root/linux-$kernel_version.tar.xz"
  
  manifest_add "source: kernel $kernel_url"
  
  if [[ ! -f "$kernel_tar" ]]; then
    download_file "$kernel_url" "$kernel_tar"
  fi
  manifest_add "download: $kernel_url sha256=$(sha256sum "$kernel_tar" | awk '{print $1}')"
  
  if [[ ! -d "$kernel_src" ]]; then
    tar -xJf "$kernel_tar" -C "$cache_root"
  fi
fi

mkdir -p "$kernel_out"
cp "$kernel_config" "$kernel_out/.config"

PATH="$tool_prefix/bin:$PATH" "$kernel_src/scripts/kconfig/merge_config.sh" -m -O "$kernel_out" "$kernel_config" >/dev/null

PATH="$tool_prefix/bin:$PATH" make -C "$kernel_src" O="$kernel_out" olddefconfig >/dev/null
PATH="$tool_prefix/bin:$PATH" make -C "$kernel_src" O="$kernel_out" -j"${BUILD_KERNEL_JOBS:-1}" bzImage modules >/dev/null

cp "$kernel_out/arch/x86/boot/bzImage" "$kernel_build_dir/vmlinuz"
cp "$kernel_out/System.map" "$kernel_build_dir/System.map"

# Install kernel modules into a staging directory so build-rootfs.sh can
# copy them into the rootfs.  Strips debug info to save space.
modules_stage="$kernel_build_dir/modules"
rm -rf "$modules_stage"
PATH="$tool_prefix/bin:$PATH" make -C "$kernel_src" O="$kernel_out" INSTALL_MOD_PATH="$modules_stage" INSTALL_MOD_STRIP=1 modules_install >/dev/null

# Record the config hash so subsequent builds can skip a rebuild when the
# config hasn't changed.
printf 'config_hash=%s\n' "$kernel_config_hash" > "$kernel_out_cache"

echo "kernel build complete: $kernel_build_dir/vmlinuz"
