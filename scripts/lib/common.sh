#!/usr/bin/env bash
set -euo pipefail

# Common helpers for repo-local build scripts.

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

_abspath_dir() {
  # Print the canonical absolute path of a directory.
  local d="$1"
  (cd "$d" >/dev/null 2>&1 && pwd -P) || return 1
}

repo_root() {
  # Resolve the repo root based on the location of this file:
  #   scripts/lib/common.sh -> repo root is ../..
  local lib_dir root
  lib_dir="$(_abspath_dir "$(dirname "${BASH_SOURCE[0]}")")" || die "cannot resolve common.sh directory"
  root="$(_abspath_dir "$lib_dir/../..")" || die "cannot resolve repo root"

  # Sanity checks: these paths must exist relative to the resolved root.
  [[ -f "$root/scripts/lib/common.sh" ]] || die "repo root sanity check failed (missing scripts/lib/common.sh): $root"
  [[ -f "$root/build.sh" ]] || die "repo root sanity check failed (missing build.sh): $root"

  # Optional: if git is present and this is a git checkout, ensure git agrees.
  if command -v git >/dev/null 2>&1 && [[ -d "$root/.git" ]]; then
    local git_root
    git_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -z "$git_root" || "$git_root" == "$root" ]] || die "git root mismatch: expected $root, got $git_root"
  fi

  echo "$root"
}

ensure_dir() {
  # Ensure a directory exists, but refuse to create paths outside the repo.
  local target="$1"
  [[ -n "$target" ]] || die "ensure_dir: empty path"

  local root
  root="$(repo_root)"

  # Convert to absolute path relative to the repo root if needed.
  local abs_target
  if [[ "$target" == /* ]]; then
    abs_target="$target"
  else
    abs_target="$root/$target"
  fi

  # Canonicalize the target before doing any "inside root" checks. This avoids
  # raw-string prefix matches being tricked by ".." segments and also catches
  # existing symlink components that resolve outside the repo.
  local canon="/"
  local rel part next
  local -a parts
  rel="${abs_target#/}"
  IFS='/' read -r -a parts <<< "$rel"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != "." ]] || continue
    if [[ "$part" == ".." ]]; then
      [[ "$canon" == "/" ]] || canon="$(dirname "$canon")"
      continue
    fi

    if [[ "$canon" == "/" ]]; then
      next="/$part"
    else
      next="$canon/$part"
    fi

    if [[ -e "$next" ]]; then
      [[ -d "$next" ]] || die "ensure_dir: path component exists but is not a directory: $next"
      canon="$(_abspath_dir "$next")" || die "ensure_dir: cannot resolve path component: $next"
    else
      canon="$next"
    fi
  done

  if [[ "$canon" != "$root" ]]; then
    local root_len=${#root}
    if [[ "${canon:0:root_len}" != "$root" || "${canon:root_len:1}" != "/" ]]; then
      die "refusing to create directory outside repo: $target"
    fi
  fi

  mkdir -p -- "$canon"
}

manifest_path() {
  local root
  root="$(repo_root)"
  echo "${BUILD_MANIFEST_FILE:-$root/build/build.manifest}"
}

manifest_add() {
  local line="${1:-}"
  [[ -n "$line" ]] || die "manifest_add: empty line"
  local path
  path="$(manifest_path)"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$line" >> "$path"
}

download_file() {
  local url="${1:-}"
  local dest="${2:-}"
  local skip_if_exists="${3:-0}"
  [[ -n "$url" && -n "$dest" ]] || die "download_file: usage url dest [skip_if_exists]"
  mkdir -p "$(dirname "$dest")"
  if [[ "$skip_if_exists" == "1" && -f "$dest" && -s "$dest" ]]; then
    echo "  [CACHED] $(basename "$dest")"
    return 0
  fi
  # Support resume for partial downloads
  local curl_args=(-fsSL --retry 3 --retry-delay 5 --connect-timeout 30)
  if [[ -f "$dest" ]]; then
    curl_args+=(-C -)  # Resume partial download
  fi
  curl "${curl_args[@]}" "$url" -o "$dest"
}

_cleanup_cmds=()
cleanup_on_exit() {
  # Register a command (passed as a single string) to run on exit.
  # Example: cleanup_on_exit 'rm -rf "$tmpdir"'
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || die "cleanup_on_exit: empty command"
  _cleanup_cmds+=("$cmd")

  # Install the trap once.
  if [[ "${#_cleanup_cmds[@]}" -eq 1 ]]; then
    trap _run_cleanups EXIT INT TERM
  fi
}

_run_cleanups() {
  local i
  # Run in reverse order (LIFO).
  for ((i=${#_cleanup_cmds[@]}-1; i>=0; i--)); do
    # shellcheck disable=SC2086
    eval "${_cleanup_cmds[$i]}" || true
  done
}
