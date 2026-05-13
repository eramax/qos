#!/bin/sh
set -eu

slots_file="${RESET_SLOTS_FILE:-/etc/qos/slots.json}"
state_label="${RESET_STATE_LABEL:-qos-state}"
bb=/bin/busybox

[ -f "$slots_file" ] || { echo "error: missing slot manifest: $slots_file" >&2; exit 1; }
[ -x "$bb" ] || { echo "error: missing busybox binary: $bb" >&2; exit 1; }

state_dev="$("$bb" findfs "LABEL=$state_label")"
mount_point="$("$bb" mktemp -d /tmp/qos-reset.XXXXXX)"
cleanup() {
  "$bb" umount "$mount_point" >/dev/null 2>&1 || true
  "$bb" rmdir "$mount_point" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

"$bb" mount "$state_dev" "$mount_point"

for path in "$mount_point"/* "$mount_point"/.[!.]* "$mount_point"/..?*; do
  [ -e "$path" ] || continue
  "$bb" rm -rf -- "$path"
done

"$bb" mkdir -p \
  "$mount_point/var/lib/qos" \
  "$mount_point/var/log" \
  "$mount_point/overlay/upper" \
  "$mount_point/overlay/work" \
  "$mount_point/etc"

cp "$slots_file" "$mount_point/var/lib/qos/slot-state.json"

echo "factory reset complete"
