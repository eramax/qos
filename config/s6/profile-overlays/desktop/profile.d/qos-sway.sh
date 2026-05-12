#!/bin/sh
# qos-sway.sh — launch Sway on first interactive login on tty1.
#
# Sourced by /etc/profile (busybox shell). Only fires for the autologin
# session on tty1, and only when Sway is installed and no Wayland
# compositor is already running.

# Interactive login on tty1 only.
case "$-" in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
[ "$(tty 2>/dev/null)" = "/dev/tty1" ] || return 0 2>/dev/null || exit 0
[ -z "${WAYLAND_DISPLAY:-}" ] || return 0 2>/dev/null || exit 0
[ -z "${SWAY_AUTOSTART_DONE:-}" ] || return 0 2>/dev/null || exit 0
command -v sway >/dev/null 2>&1 || return 0 2>/dev/null || exit 0

export SWAY_AUTOSTART_DONE=1
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# WLR_RENDERER=pixman is a safe CPU fallback when no working GPU is
# present (Wayland still renders, just on the CPU). Drop it once
# DRM/virtio-gpu is proven on this build.
exec env WLR_RENDERER="${WLR_RENDERER:-pixman}" sway
