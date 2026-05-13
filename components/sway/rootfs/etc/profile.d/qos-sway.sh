#!/bin/sh

chmod 666 /dev/null 2>&1 || true

LOG="/run/qos/sway.log"

log() { printf '[qos-sway] %s\n' "$*" >> "$LOG" 2>/dev/null; }

mkdir -p /run/qos 2>/dev/null || true

[ "$(tty 2>/dev/null)" = "/dev/tty1" ] || { log "skip: not tty1 ($(tty 2>/dev/null))"; return 0 2>/dev/null || exit 0; }
[ -z "${WAYLAND_DISPLAY:-}" ] || { log "skip: WAYLAND_DISPLAY already set"; return 0 2>/dev/null || exit 0; }
command -v sway >/dev/null 2>&1 || { log "skip: sway not found"; return 0 2>/dev/null || exit 0; }

retry_file="/run/qos/sway-attempts"
max_attempts=3

attempts=0
[ -f "$retry_file" ] && attempts="$(cat "$retry_file" 2>/dev/null)" || true
attempts=$((attempts + 1))
printf '%d\n' "$attempts" > "$retry_file"
[ "$attempts" -le "$max_attempts" ] || { log "skip: $attempts attempts exceeded max $max_attempts"; return 0 2>/dev/null || exit 0; }

log "attempt $attempts/$max_attempts"

for _mod in virtio_gpu amdgpu radeon i915 nouveau; do
  modprobe "$_mod" 2>/dev/null || true
done

log "waiting for /dev/dri/card0 ..."
_n=0; while [ ! -e /dev/dri/card0 ] && [ "$_n" -lt 60 ]; do sleep 0.25; _n=$((_n+1)); done
if [ ! -e /dev/dri/card0 ]; then
  log "FATAL: /dev/dri/card0 not found after 15s"
  log "ls /dev/dri: $(ls /dev/dri 2>/dev/null || echo '(empty)')"
  log "lspci: $(lspci 2>/dev/null || echo 'n/a')"
  return 0 2>/dev/null || exit 0
fi
log "/dev/dri/card0 found"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export LIBSEAT_BACKEND="${LIBSEAT_BACKEND:-seatd}"
export WLR_DRM_NO_MODIFIERS=1
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

log "starting sway (renderer=pixman, backend=drm, seatd) ..."
exec sway -d 2>>"$LOG"
