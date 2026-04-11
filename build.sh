#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/scripts/lib/common.sh"

ROOT="$(repo_root)"

# Contract: refuse to run if the user is not somewhere inside this workspace.
pwd_abs="$(pwd -P)"
case "$pwd_abs" in
  "$ROOT" | "$ROOT/"*) ;;
  *) die "refusing to run outside workspace. cd into $ROOT (or a subdir) and re-run." ;;
esac

ensure_dir "$ROOT/build"
ensure_dir "$ROOT/dist"

echo "build scaffold ok: created/verified build/ and dist/ under $ROOT"

