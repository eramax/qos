#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
rootfs="${ROOTFS_DIR:-$root/build/rootfs}"
dropbear_keys_file="${DROPBEAR_AUTHORIZED_KEYS_FILE:-$root/config/dropbear/authorized_keys}"

[[ -d "$rootfs" ]] || die "missing rootfs dir: $rootfs"

etc_dir="$rootfs/etc"
[[ -d "$etc_dir" ]] || die "missing /etc in rootfs: $etc_dir"

chmod u+w "$etc_dir"
chmod u+w "$rootfs/root"

# Set hostname.
printf 'qos\n' > "$etc_dir/hostname"

# Generate stable dropbear host keys so the SSH fingerprint survives rebuilds.
mkdir -p "$etc_dir/dropbear"
dbkey="$rootfs/usr/bin/dropbearkey"
if [[ -x "$dbkey" ]] && ! [[ -f "$etc_dir/dropbear/dropbear_ed25519_host_key" ]]; then
  "$dbkey" -t ed25519 -f "$etc_dir/dropbear/dropbear_ed25519_host_key" >/dev/null 2>&1 || true
fi
if [[ -x "$dbkey" ]] && ! [[ -f "$etc_dir/dropbear/dropbear_rsa_host_key" ]]; then
  "$dbkey" -t rsa -f "$etc_dir/dropbear/dropbear_rsa_host_key" >/dev/null 2>&1 || true
fi

# Set root password to "root" for dev/test access.
# Uses openssl to generate a SHA-512 crypt hash; awk writes it safely
# (avoids sed misinterpreting $ in the hash).
if [[ -f "$etc_dir/shadow" ]]; then
  chmod u+w "$etc_dir/shadow"
  root_pw_hash="$(openssl passwd -6 root)"
  awk -v pw="$root_pw_hash" 'BEGIN{FS=OFS=":"} $1=="root"{$2=pw}1' \
    "$etc_dir/shadow" > "$etc_dir/shadow.tmp"
  mv "$etc_dir/shadow.tmp" "$etc_dir/shadow"
  chmod 0400 "$etc_dir/shadow"
fi

mkdir -p "$etc_dir/s6/service-tree" "$etc_dir/s6/s6-rc.d" "$etc_dir/dropbear" "$etc_dir/nftables" "$etc_dir/network" "$etc_dir/cloud/cloud.cfg.d"
mkdir -p "$etc_dir/profile.d" "$etc_dir/qos"

# Ensure /etc/qos and subdirectories are writable (created read-only in rootfs layout)
chmod -R u+w "$etc_dir/qos" 2>/dev/null || mkdir -p "$etc_dir/qos"
mkdir -p "$etc_dir/qos/capabilities" "$etc_dir/qos/cluster" "$etc_dir/caddy" "$etc_dir/chrony"
mkdir -p "$rootfs/root/.ssh"

cp -a "$root/config/s6/service-tree/." "$etc_dir/s6/service-tree/"
cp -a "$root/config/s6/s6-rc.d/." "$etc_dir/s6/s6-rc.d/"

# Profile-aware service overlay. QOS_PROFILE selects which extra service
# templates from config/s6/profile-overlays/<profile>/ get staged. Default
# is `server`, which has no overlay directory, so this is a no-op for the
# current build path. See docs/FEATURE-REVIEW-AND-IDEAS.md §2.6.
qos_profile="${QOS_PROFILE:-server}"
overlay_dir="$root/config/s6/profile-overlays/$qos_profile"
if [[ -d "$overlay_dir/service-tree" ]]; then
  cp -a "$overlay_dir/service-tree/." "$etc_dir/s6/service-tree/"
fi
if [[ -d "$overlay_dir/s6-rc.d" ]]; then
  cp -a "$overlay_dir/s6-rc.d/." "$etc_dir/s6/s6-rc.d/"
fi
# Profile may also ship /etc/profile.d snippets — e.g. desktop autostarts
# sway on tty1 via config/s6/profile-overlays/desktop/profile.d/qos-sway.sh.
if [[ -d "$overlay_dir/profile.d" ]]; then
  for snippet in "$overlay_dir/profile.d"/*.sh; do
    [[ -f "$snippet" ]] || continue
    install -m 0755 "$snippet" "$etc_dir/profile.d/$(basename "$snippet")"
  done
fi
mkdir -p "$etc_dir/qos"
printf '%s\n' "$qos_profile" > "$etc_dir/qos/profile"
if [[ -d "$root/config/cloud" ]]; then
  cp -a "$root/config/cloud/." "$etc_dir/cloud/"
fi
if [[ -f "$etc_dir/cloud/cloud.cfg" ]]; then
  tmp_cloud_cfg="$etc_dir/cloud/cloud.cfg.tmp"
  awk '
    BEGIN { replaced = 0 }
    /^[[:space:]]*datasource_list:/ {
      print "datasource_list: [ ConfigDrive, NoCloud, None ]"
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print "datasource_list: [ ConfigDrive, NoCloud, None ]"
      }
    }
  ' "$etc_dir/cloud/cloud.cfg" > "$tmp_cloud_cfg"
  mv "$tmp_cloud_cfg" "$etc_dir/cloud/cloud.cfg"
fi
rm -f "$etc_dir/cloud/cloud.cfg.d/05_qos-cloud-init.cfg"
if [[ -n "${QOS_BUILD_VERSION:-}" ]]; then
  printf '%s\n' "$QOS_BUILD_VERSION" > "$etc_dir/qos/version"
else
  printf '%s\n' 'QOS build: unknown' > "$etc_dir/qos/version"
fi
chmod 0444 "$etc_dir/qos/version"
printf '%s\n' 'installed-disk' > "$etc_dir/qos/boot-source"
chmod 0444 "$etc_dir/qos/boot-source"

install -m 0644 "$root/config/dropbear/dropbear.conf" "$etc_dir/dropbear/dropbear.conf"
if [[ -f "$root/config/profile.d/qos-banner.sh" ]]; then
  install -m 0755 "$root/config/profile.d/qos-banner.sh" "$etc_dir/profile.d/qos-banner.sh"
fi
if [[ -f "$dropbear_keys_file" ]]; then
  install -m 0600 "$dropbear_keys_file" "$rootfs/root/.ssh/authorized_keys"
fi
install -m 0644 "$root/config/nftables/nftables.conf" "$etc_dir/nftables/nftables.conf"
install -m 0644 "$root/config/network/interfaces.dhcp" "$etc_dir/network/interfaces.dhcp"
printf 'QOS\n' > "$etc_dir/motd"
chmod 0444 "$etc_dir/motd"

# Install capability profiles
if [[ -d "$root/config/qos/capabilities/profiles" ]]; then
  chmod u+w "$etc_dir/qos/capabilities" 2>/dev/null || true
  mkdir -p "$etc_dir/qos/capabilities/profiles"
  cp -a "$root/config/qos/capabilities/profiles/." "$etc_dir/qos/capabilities/profiles/"
fi

# Install cluster configuration
if [[ -f "$root/config/qos/cluster/node.conf" ]]; then
  chmod u+w "$etc_dir/qos/cluster" 2>/dev/null || true
  install -m 0644 "$root/config/qos/cluster/node.conf" "$etc_dir/qos/cluster/node.conf"
fi

# Install caddy configuration if caddy is available
if [[ -d "$root/config/caddy" ]] && [[ -f "$rootfs/usr/bin/caddy" ]]; then
  mkdir -p "$etc_dir/caddy"
  cp -a "$root/config/caddy/." "$etc_dir/caddy/"
fi

# Install qos-capability and qos-cluster scripts
chmod u+w "$rootfs/usr/bin" 2>/dev/null || true
ln -sfn /bin/busybox "$rootfs/usr/bin/env"
if [[ -f "$root/scripts/qos-capability.sh" ]]; then
  install -m 0755 "$root/scripts/qos-capability.sh" "$rootfs/usr/bin/qos-capability"
fi
if [[ -f "$root/scripts/qos-cluster.sh" ]]; then
  install -m 0755 "$root/scripts/qos-cluster.sh" "$rootfs/usr/bin/qos-cluster"
fi
if [[ -f "$root/scripts/qos-expand.sh" ]]; then
  install -m 0755 "$root/scripts/qos-expand.sh" "$rootfs/usr/bin/qos-expand"
fi
if [[ -f "$root/scripts/qos-test.sh" ]]; then
  install -m 0755 "$root/scripts/qos-test.sh" "$rootfs/usr/bin/qos-test"
fi
if [[ -f "$root/scripts/qos-install.sh" ]]; then
  install -m 0755 "$root/scripts/qos-install.sh" "$rootfs/usr/bin/qos-install"
fi
if [[ -f "$root/scripts/qos-e2e-full.sh" ]]; then
  install -m 0755 "$root/scripts/qos-e2e-full.sh" "$rootfs/usr/bin/qos-e2e-full"
fi
if [[ -f "$root/scripts/qos.sh" ]]; then
  install -m 0755 "$root/scripts/qos.sh" "$rootfs/usr/bin/qos"
fi
if [[ -f "$root/scripts/qos-manifest.sh" ]]; then
  install -m 0755 "$root/scripts/qos-manifest.sh" "$rootfs/usr/bin/qos-manifest"
fi
if [[ -f "$root/scripts/qos-ota.sh" ]]; then
  install -m 0755 "$root/scripts/qos-ota.sh" "$rootfs/usr/bin/qos-ota"
fi
if [[ -f "$root/scripts/lib/test-common.sh" ]]; then
  install -d -m 0755 "$rootfs/usr/lib"
  install -m 0644 "$root/scripts/lib/test-common.sh" "$rootfs/usr/lib/qos-test-common.sh"
fi

# Ensure a udhcpc default script exists so that a granted DHCP lease actually
# configures the interface.  Alpine's busybox package usually ships this file,
# but provide a fallback in case --no-scripts leaves it out.
udhcpc_script_dir="$rootfs/usr/share/udhcpc"
if [[ ! -f "$udhcpc_script_dir/default.script" ]]; then
  chmod u+w "$rootfs/usr" "$rootfs/usr/share" 2>/dev/null || true
  mkdir -p "$udhcpc_script_dir"
  cat > "$udhcpc_script_dir/default.script" <<'UDHCPC_SCRIPT'
#!/bin/sh
# Minimal udhcpc bound/renew script.
case "$1" in
  bound|renew)
    [ -n "$ip" ]     && /bin/busybox ip addr replace "${ip}/${mask:-24}" dev "$interface"
    [ -n "$router" ] && /bin/busybox ip route replace default via "$router" dev "$interface"
    ;;
  deconfig)
    /bin/busybox ip addr flush dev "$interface"
    /bin/busybox ip route del default 2>/dev/null || true
    ;;
esac
UDHCPC_SCRIPT
  chmod 0755 "$udhcpc_script_dir/default.script"
fi

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
    -p /usr/sbin:/usr/bin:/sbin:/bin \
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

/usr/bin/s6-linux-init -v 1 -m 0022 -c "/etc/s6-linux-init/current" -p "/usr/sbin:/usr/bin:/sbin:/bin" -D "default" -- "$@"
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
chmod a-w "$rootfs/root"

echo "service configs staged into $rootfs"
