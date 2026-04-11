#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/scripts/lib/common.sh"

ROOT="$(repo_root)"

# Contract: refuse to run if the user is not somewhere inside this workspace.
pwd_abs="$(pwd -P)"
if [[ "$pwd_abs" != "$ROOT" ]]; then
  root_len=${#ROOT}
  if [[ "${pwd_abs:0:root_len}" != "$ROOT" || "${pwd_abs:root_len:1}" != "/" ]]; then
    die "refusing to run outside workspace. cd into $ROOT (or a subdir) and re-run."
  fi
fi

ensure_dir "$ROOT/build"
ensure_dir "$ROOT/dist"

echo "build scaffold ok: created/verified build/ and dist/ under $ROOT"
