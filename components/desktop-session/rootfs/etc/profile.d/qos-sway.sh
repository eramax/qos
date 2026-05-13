#!/bin/sh
# qos-sway.sh — launch Sway on first interactive login on tty1.

case "$-" in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
[ "$(tty 2>/dev/null)" = "/dev/tty1" ] || return 0 2>/dev/null || exit 0
[ -z "${WAYLAND_DISPLAY:-}" ] || return 0 2>/dev/null || exit 0
command -v sway >/dev/null 2>&1 || return 0 2>/dev/null || exit 0

retry_file="/run/qos/sway-attempts"
max_attempts=3
mkdir -p /run/qos 2>/dev/null || true

attempts=0
[ -f "$retry_file" ] && attempts="$(cat "$retry_file" 2>/dev/null)" || true
attempts=$((attempts + 1))
printf '%d\n' "$attempts" > "$retry_file"
[ "$attempts" -le "$max_attempts" ] || return 0 2>/dev/null || exit 0

for _mod in virtio-gpu amdgpu radeon i915 nouveau; do
  modprobe "$_mod" 2>/dev/null || true
done

_n=0; while [ ! -e /dev/dri/card0 ] && [ "$_n" -lt 60 ]; do sleep 0.25; _n=$((_n+1)); done
[ -e /dev/dri/card0 ] || return 0 2>/dev/null || exit 0

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export LIBSEAT_BACKEND="${LIBSEAT_BACKEND:-seatd}"
export WLR_RENDERER=pixman
export WLR_DRM_NO_MODIFIERS=1
export WLR_LIBINPUT_NO_DEVICES=1
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
exec sway
