#!/usr/bin/env bash
# Build QOS inside a pinned Podman container. This is a thin wrapper —
# the actual build logic lives unchanged in build.sh.
#
# Step 1 of the phased rollout in docs/FEATURE-REVIEW-AND-IDEAS.md:
# containerize the existing build with zero logic changes.

set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/../lib/common.sh"

ROOT="$(repo_root)"
IMAGE_TAG="${QOS_BUILDER_IMAGE:-qos-builder:local}"
CONTAINER_TOOL="${QOS_CONTAINER_TOOL:-podman}"

command -v "$CONTAINER_TOOL" >/dev/null 2>&1 \
  || die "$CONTAINER_TOOL not found. Install podman (or set QOS_CONTAINER_TOOL=docker)."

build_image() {
  # Rebuild only when the Containerfile is newer than the image, or when
  # the image is missing. Skip the check when QOS_BUILDER_REBUILD=1.
  if [[ "${QOS_BUILDER_REBUILD:-0}" != "1" ]] \
    && "$CONTAINER_TOOL" image exists "$IMAGE_TAG" >/dev/null 2>&1; then
    return 0
  fi
  echo "==> building $IMAGE_TAG from Containerfile"
  "$CONTAINER_TOOL" build -t "$IMAGE_TAG" -f "$ROOT/Containerfile" "$ROOT"
}

run_build() {
  # Pass through build knobs so users can keep using the same env vars
  # they use with `make full`. BUILD_MOCK defaults to 1 inside the
  # container, matching repo conventions.
  local envs=(
    -e "BUILD_MOCK=${BUILD_MOCK:-1}"
    -e "BUILD_KERNEL_JOBS=${BUILD_KERNEL_JOBS:-$(nproc)}"
    -e "BUILD_TOOL_JOBS=${BUILD_TOOL_JOBS:-$(nproc)}"
  )
  if [[ -n "${DROPBEAR_AUTHORIZED_KEYS_FILE:-}" ]]; then
    envs+=(-e "DROPBEAR_AUTHORIZED_KEYS_FILE=${DROPBEAR_AUTHORIZED_KEYS_FILE}")
  fi

  # Mount the repo read-write so build/ and dist/ outputs land back on
  # the host. :Z is harmless on non-SELinux hosts under podman.
  local mount_flag=":Z"
  if [[ "$CONTAINER_TOOL" != "podman" ]]; then
    mount_flag=""
  fi

  echo "==> building inside $IMAGE_TAG (BUILD_MOCK=${BUILD_MOCK:-1})"
  "$CONTAINER_TOOL" run --rm \
    --userns=keep-id \
    "${envs[@]}" \
    -v "$ROOT:/work${mount_flag}" \
    -w /work \
    "$IMAGE_TAG" \
    bash build.sh "$@"
}

build_image
run_build "$@"
