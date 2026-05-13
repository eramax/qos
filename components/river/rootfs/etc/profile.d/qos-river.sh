#!/bin/sh

LOG="/run/qos/river.log"
log() { printf '[qos-river] %s\n' "$*" >> "$LOG" 2>/dev/null; }

mkdir -p /run/qos 2>/dev/null || true

case "$-" in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
[ "$(tty 2>/dev/null)" = "/dev/tty1" ] || { log "skip: not tty1 ($(tty 2>/dev/null))"; return 0 2>/dev/null || exit 0; }
[ -z "${WAYLAND_DISPLAY:-}" ] || { log "skip: WAYLAND_DISPLAY set"; return 0 2>/dev/null || exit 0; }
command -v river >/dev/null 2>&1 || { log "skip: river not found"; return 0 2>/dev/null || exit 0; }

retry_file="/run/qos/river-attempts"
max_attempts=3

attempts=0
[ -f "$retry_file" ] && attempts="$(cat "$retry_file" 2>/dev/null)" || true
attempts=$((attempts + 1))
printf '%d\n' "$attempts" > "$retry_file"
[ "$attempts" -le "$max_attempts" ] || { log "skip: $attempts attempts exceeded max $max_attempts"; return 0 2>/dev/null || exit 0; }

log "attempt $attempts/$max_attempts"

for _mod in virtio-gpu amdgpu radeon i915 nouveau; do
  modprobe "$_mod" 2>/dev/null || true
done

log "waiting for /dev/dri/card0 ..."
_n=0; while [ ! -e /dev/dri/card0 ] && [ "$_n" -lt 60 ]; do sleep 0.25; _n=$((_n+1)); done
if [ ! -e /dev/dri/card0 ]; then
  log "FATAL: /dev/dri/card0 not found after 15s"
  log "ls /dev/dri: $(ls /dev/dri 2>/dev/null || echo '(empty)')"
  return 0 2>/dev/null || exit 0
fi
log "/dev/dri/card0 found"

log "waiting for /dev/input/event0 ..."
_n=0; while [ ! -e /dev/input/event0 ] && [ "$_n" -lt 120 ]; do sleep 0.25; _n=$((_n+1)); done
if [ -e /dev/input/event0 ]; then
  log "/dev/input/event0 found"
  udevadm trigger --action=change /sys/class/input/* 2>/dev/null || true
  sleep 0.5
else
  log "WARN: /dev/input/event0 not found after 30s, retrying with WLR_LIBINPUT_NO_DEVICES=1"
  export WLR_LIBINPUT_NO_DEVICES=1
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/root/.config}"
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_CLASS=user
export XDG_VTNR=1
export LIBSEAT_BACKEND="${LIBSEAT_BACKEND:-seatd}"
export WLR_RENDERER=pixman
export WLR_DRM_NO_MODIFIERS=1
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

chmod +x "${XDG_CONFIG_HOME}/river/init" 2>/dev/null || true

log "starting river (renderer=pixman, seatd) ..."
exec river 2>>"$LOG"
