#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
rootfs="${ROOTFS_DIR:-$root/build/rootfs}"

[[ -d "$rootfs" ]] || die "missing rootfs dir: $rootfs"

etc_dir="$rootfs/etc"
[[ -d "$etc_dir" ]] || die "missing /etc in rootfs: $etc_dir"

chmod u+w "$etc_dir"
mkdir -p "$etc_dir/s6/service-tree" "$etc_dir/s6/s6-rc.d" "$etc_dir/dropbear" "$etc_dir/nftables" "$etc_dir/network"

cp -a "$root/config/s6/service-tree/." "$etc_dir/s6/service-tree/"
cp -a "$root/config/s6/s6-rc.d/." "$etc_dir/s6/s6-rc.d/"
install -m 0644 "$root/config/dropbear/dropbear.conf" "$etc_dir/dropbear/dropbear.conf"
install -m 0644 "$root/config/nftables/nftables.conf" "$etc_dir/nftables/nftables.conf"
install -m 0644 "$root/config/network/interfaces.dhcp" "$etc_dir/network/interfaces.dhcp"

s6_base_dir="$etc_dir/s6-linux-init"
s6_skel_dir="$s6_base_dir/skel"
s6_current_dir="$s6_base_dir/current"
maker_bin="$rootfs/usr/bin/s6-linux-init-maker"
maker_loader="$rootfs/lib/ld-musl-x86_64.so.1"
if [[ -x "$maker_bin" && -x "$maker_loader" ]]; then
  maker_stage_dir="$(mktemp -u "$root/build/cache/s6-linux-init.XXXXXX")"
  cleanup_maker_stage() {
    chmod -R u+w "$maker_stage_dir" 2>/dev/null || true
    rm -rf "$maker_stage_dir"
  }
  trap cleanup_maker_stage EXIT INT TERM

  LD_LIBRARY_PATH="$rootfs/lib:$rootfs/usr/lib" \
    "$maker_loader" "$maker_bin" \
    -1 \
    -D default \
    -p /usr/bin:/bin \
    -G "/sbin/getty 38400 tty1" \
    -f "$s6_skel_dir" \
    "$maker_stage_dir" >/dev/null

  chmod -R u+w "$s6_current_dir" 2>/dev/null || true
  rm -rf "$s6_current_dir"
  cp -a "$maker_stage_dir" "$s6_current_dir"

  cat > "$s6_current_dir/scripts/rc.init" <<'EOF'
#!/bin/sh -e

service_root=/run/service

mkdir -p "$service_root"
for service in /etc/s6/service-tree/*; do
  [ -e "$service" ] || continue
  name="${service##*/}"
  rm -rf "$service_root/$name"
  cp -a "$service" "$service_root/$name"
  chmod 0755 "$service_root/$name"
done

exec /usr/bin/s6-svscanctl -a "$service_root"
EOF
  chmod 0755 "$s6_current_dir/scripts/rc.init"

  cat > "$s6_current_dir/scripts/runlevel" <<'EOF'
#!/bin/sh -e

exec /etc/s6-linux-init/current/scripts/rc.init "$@"
EOF
  chmod 0755 "$s6_current_dir/scripts/runlevel"

  cat > "$s6_current_dir/bin/init" <<'EOF'
#!/usr/bin/execlineb -S0

/usr/bin/s6-linux-init -v 1 -m 0022 -c "/etc/s6-linux-init/current" -p "/usr/bin:/bin" -D "default" -- "$@"
EOF
  cat > "$s6_current_dir/bin/halt" <<'EOF'
#!/usr/bin/execlineb -S0

/usr/bin/s6-linux-init-hpr -h $@
EOF
  cat > "$s6_current_dir/bin/poweroff" <<'EOF'
#!/usr/bin/execlineb -S0

/usr/bin/s6-linux-init-hpr -p $@
EOF
  cat > "$s6_current_dir/bin/reboot" <<'EOF'
#!/usr/bin/execlineb -S0

/usr/bin/s6-linux-init-hpr -r $@
EOF
  cat > "$s6_current_dir/bin/shutdown" <<'EOF'
#!/usr/bin/execlineb -S0

/usr/bin/s6-linux-init-shutdown $@
EOF
  cat > "$s6_current_dir/bin/telinit" <<'EOF'
#!/usr/bin/execlineb -S0

/usr/bin/s6-linux-init-telinit $@
EOF

  chmod u+w "$rootfs/sbin"
  rm -f "$rootfs/sbin/init"
  ln -s /etc/s6-linux-init/current/bin/init "$rootfs/sbin/init"
  for helper in halt poweroff reboot shutdown telinit; do
    rm -f "$rootfs/sbin/$helper"
    ln -s "/etc/s6-linux-init/current/bin/$helper" "$rootfs/sbin/$helper"
  done
  chmod a-w "$rootfs/sbin"
else
  chmod -R u+w "$s6_current_dir" 2>/dev/null || true
  rm -rf "$s6_current_dir"
  mkdir -p "$s6_current_dir/scripts" "$s6_current_dir/env" "$s6_current_dir/run-image/service" "$s6_current_dir/run-image/uncaught-logs"
  cat > "$s6_current_dir/scripts/rc.init" <<'EOF'
#!/bin/sh -e

service_root=/run/service

mkdir -p "$service_root"
for service in /etc/s6/service-tree/*; do
  [ -e "$service" ] || continue
  name="${service##*/}"
  rm -rf "$service_root/$name"
  cp -a "$service" "$service_root/$name"
  chmod 0755 "$service_root/$name"
done

exec /usr/bin/s6-svscanctl -a "$service_root"
EOF
  cat > "$s6_current_dir/scripts/runlevel" <<'EOF'
#!/bin/sh -e

exec /etc/s6-linux-init/current/scripts/rc.init "$@"
EOF
  chmod 0755 "$s6_current_dir/scripts/rc.init" "$s6_current_dir/scripts/runlevel"
fi

# Re-harden the staged configuration tree for the immutable image.
chmod -R a-w "$etc_dir"

echo "service configs staged into $rootfs"
