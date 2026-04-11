#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

[[ -f "$repo_root/build.sh" ]] || die "missing build.sh at repo root"
[[ -f "$repo_root/scripts/lib/common.sh" ]] || die "missing scripts/lib/common.sh"

tmprepo="$(mktemp -d)"
outside="$(mktemp -d)"
cleanup() {
  rm -rf "$tmprepo" "$outside"
}
trap cleanup EXIT INT TERM

# Create a minimal synthetic repo to keep this test deterministic and avoid
# depending on untracked files in the working tree.
mkdir -p "$tmprepo/scripts/lib"
cp "$repo_root/build.sh" "$tmprepo/build.sh"
cp "$repo_root/scripts/lib/common.sh" "$tmprepo/scripts/lib/common.sh"
chmod +x "$tmprepo/build.sh"

# 1) Must refuse to run when invoked from outside the workspace.
(
  cd "$outside"
  set +e
  "$tmprepo/build.sh" >/dev/null 2>&1
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || die "expected build.sh to fail when run outside workspace"
)
[[ ! -e "$outside/build" ]] || die "build.sh created build/ outside workspace"
[[ ! -e "$outside/dist" ]] || die "build.sh created dist/ outside workspace"

# 2) Must succeed when run inside the workspace and only create build/ and dist/.
(
  cd "$tmprepo"
  ./build.sh >/dev/null
)
[[ -d "$tmprepo/build" ]] || die "expected build/ to exist in workspace"
[[ -d "$tmprepo/dist" ]] || die "expected dist/ to exist in workspace"

# Ensure no unexpected paths were created. This must include directories too,
# otherwise unexpected directory creation can slip through undetected.
expected_paths="$(printf '%s\n' \
  "build.sh" \
  "build" \
  "dist" \
  "scripts" \
  "scripts/lib" \
  "scripts/lib/common.sh" \
  | sort)"
actual_paths="$(cd "$tmprepo" && find . -mindepth 1 -print | sed 's#^./##' | sort)"
[[ "$actual_paths" == "$expected_paths" ]] || {
  echo "expected paths:" >&2
  echo "$expected_paths" >&2
  echo "actual paths:" >&2
  echo "$actual_paths" >&2
  die "unexpected paths created in workspace"
}

echo "ok"
