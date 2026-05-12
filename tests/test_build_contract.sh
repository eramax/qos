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
grep -qF 'help2man' "$repo_root/build.sh" || die "build.sh must require host help2man"
grep -qF 'indent' "$repo_root/build.sh" || die "build.sh must require GNU indent"
grep -qF 'build complete: dist/qos-x86_64.iso' "$repo_root/build.sh" || die "build.sh must report ISO completion"
! grep -qF 'build complete: dist/qos-x86_64.raw' "$repo_root/build.sh" || die "build.sh must not report raw image completion"
grep -qF 'scripts/build-iso.sh' "$repo_root/build.sh" || die "build.sh must build the live ISO"
grep -qF 'build/kernel/build/arch/x86/boot/bzImage' "$repo_root/build.sh" || die "build.sh must reuse the real kernel bzImage path"
grep -qF 'interface_branding: QOS Live via Limine' "$repo_root/scripts/build-iso.sh" || die "build-iso.sh must brand the live Limine interface"
grep -qF 'console=tty0 console=ttyS0,115200n8' "$repo_root/scripts/build-iso.sh" || die "build-iso.sh must keep VGA and serial consoles enabled"

tmprepo="$(mktemp -d)"
outside="$(mktemp -d)"
special_base="$(mktemp -d)"
cleanup() {
  rm -rf "$tmprepo" "$outside" "$special_base"
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

# Ensure no unexpected paths were created outside the allowed build/dist tree.
while IFS= read -r path; do
  case "$path" in
    build.sh|scripts|scripts/lib|scripts/lib/common.sh|build|dist|build/*|dist/*) ;;
    *) die "unexpected path created in workspace: $path" ;;
  esac
done < <(cd "$tmprepo" && find . -mindepth 1 -print | sed 's#^./##' | sort)

# 3) Must work when the workspace path itself contains glob metacharacters.
specialrepo="$special_base/repo[1]?"
mkdir -p "$specialrepo/scripts/lib"
cp "$repo_root/build.sh" "$specialrepo/build.sh"
cp "$repo_root/scripts/lib/common.sh" "$specialrepo/scripts/lib/common.sh"
chmod +x "$specialrepo/build.sh"
(
  cd "$specialrepo"
  ./build.sh >/dev/null
)
[[ -d "$specialrepo/build" ]] || die "expected build/ to exist in special-path workspace"
[[ -d "$specialrepo/dist" ]] || die "expected dist/ to exist in special-path workspace"

# 4) Must refuse symlink escapes for build/ and dist/.
symlinkrepo="$special_base/symlink-repo"
outside_target="$special_base/outside-target"
mkdir -p "$symlinkrepo/scripts/lib" "$outside_target"
cp "$repo_root/build.sh" "$symlinkrepo/build.sh"
cp "$repo_root/scripts/lib/common.sh" "$symlinkrepo/scripts/lib/common.sh"
chmod +x "$symlinkrepo/build.sh"
ln -s "$outside_target" "$symlinkrepo/build"
ln -s "$outside_target" "$symlinkrepo/dist"
(
  cd "$symlinkrepo"
  set +e
  ./build.sh >/dev/null 2>&1
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || die "expected build.sh to fail when build/ and dist/ are symlink escapes"
)

echo "ok"
