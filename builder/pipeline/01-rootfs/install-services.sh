#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/../../lib/common.sh"

root="$(repo_root)"
rootfs="${ROOTFS_DIR:-$root/build/rootfs}"
dropbear_keys_file="${DROPBEAR_AUTHORIZED_KEYS_FILE:-$root/components/dropbear/authorized_keys}"

[[ -d "$rootfs" ]] || die "missing rootfs dir: $rootfs"

etc_dir="$rootfs/etc"
[[ -d "$etc_dir" ]] || die "missing /etc in rootfs: $etc_dir"

chmod u+w "$etc_dir"
chmod u+w "$rootfs/root"
chmod -R u+w "$etc_dir" 2>/dev/null || true
chmod -R u+w "$rootfs/usr/bin" 2>/dev/null || true
chmod -R u+w "$rootfs/usr/sbin" 2>/dev/null || true
chmod -R u+w "$rootfs/usr/lib" 2>/dev/null || true
chmod -R u+w "$rootfs/usr/share" 2>/dev/null || true
chmod -R u+w "$rootfs/sbin" 2>/dev/null || true

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

qos_profile="${QOS_PROFILE:-server}"
component_rootfs_dir="${COMPONENT_ROOTFS_DIR:-}"
[[ -n "$component_rootfs_dir" ]] || die "COMPONENT_ROOTFS_DIR is required"
[[ -d "$component_rootfs_dir" ]] || die "missing component rootfs stage dir: $component_rootfs_dir"
cp -a "$component_rootfs_dir/." "$rootfs/"

if ! grep -q '^emo:' "$etc_dir/passwd" 2>/dev/null; then
  emo_pw_hash="$(openssl passwd -6 123)"
  echo 'emo:x:1000:1000:emo:/home/emo:/bin/sh' >> "$etc_dir/passwd"
  chmod u+w "$etc_dir/shadow"
  echo "emo:${emo_pw_hash}:20000:0:99999:7:::" >> "$etc_dir/shadow"
  chmod 0400 "$etc_dir/shadow"
  echo 'emo:x:1000:emo' >> "$etc_dir/group"
  sed -i '/^video:/s/$/,emo/' "$etc_dir/group" 2>/dev/null || echo 'video:x:27:emo' >> "$etc_dir/group"
  sed -i '/^input:/s/$/,emo/' "$etc_dir/group" 2>/dev/null || echo 'input:x:28:emo' >> "$etc_dir/group"
  sed -i '/^wheel:/s/$/,emo/' "$etc_dir/group" 2>/dev/null || echo 'wheel:x:10:emo' >> "$etc_dir/group"
  chmod u+w "$etc_dir/sudoers" 2>/dev/null || true
  echo '%wheel ALL=(ALL) ALL' >> "$etc_dir/sudoers"
  chmod u+w "$rootfs/home" 2>/dev/null || true
  mkdir -p "$rootfs/home/emo/.config/river"
  if [ -f "$rootfs/root/.config/river/init" ]; then
    cp "$rootfs/root/.config/river/init" "$rootfs/home/emo/.config/river/init"
    chmod 0755 "$rootfs/home/emo/.config/river/init"
  fi
  chmod 0755 "$rootfs/root/.config/river/init" 2>/dev/null || true
fi

if [[ -x "$rootfs/usr/bin/dbus-daemon" ]] || [[ -x "$rootfs/usr/sbin/dbus-daemon" ]]; then
  if ! grep -q '^messagebus:' "$etc_dir/group" 2>/dev/null; then
    echo 'messagebus:x:101:' >> "$etc_dir/group"
  fi
  if ! grep -q '^messagebus:' "$etc_dir/passwd" 2>/dev/null; then
    echo 'messagebus:x:101:101:messagebus:/var/empty:/sbin/nologin' >> "$etc_dir/passwd"
  fi
  if [[ -f "$etc_dir/shadow" ]]; then
    chmod u+w "$etc_dir/shadow"
    if ! grep -q '^messagebus:' "$etc_dir/shadow" 2>/dev/null; then
      echo 'messagebus:!*:0:0::::' >> "$etc_dir/shadow"
    fi
    chmod 0400 "$etc_dir/shadow"
  fi
  if ! [[ -f "$etc_dir/machine-id" ]]; then
    chmod u+w "$etc_dir"
    cat /proc/sys/kernel/random/uuid | tr -d '-' > "$etc_dir/machine-id"
  fi
fi
find "$etc_dir/s6/service-tree" -type f -name run -exec chmod 0755 {} \;
find "$etc_dir/s6/s6-rc.d" -type f -name run -exec chmod 0755 {} \;
find "$etc_dir/profile.d" -type f -name '*.sh' -exec chmod 0755 {} \;
find "$rootfs/usr/bin" -type f -name 'qos-autologin-*' -exec chmod 0755 {} \;
mkdir -p "$etc_dir/qos"
printf '%s\n' "$qos_profile" > "$etc_dir/qos/profile"
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

if [[ -f "$dropbear_keys_file" ]]; then
  install -m 0600 "$dropbear_keys_file" "$rootfs/root/.ssh/authorized_keys"
fi
printf 'QOS\n' > "$etc_dir/motd"
chmod 0444 "$etc_dir/motd"

# Ensure env is available for scripts installed via components/qos.
chmod u+w "$rootfs/usr/bin" 2>/dev/null || true
ln -sfn /bin/busybox "$rootfs/usr/bin/env"

# VBoxService looks for VBoxDRMClient at /usr/bin/; Alpine installs it to /usr/sbin/.
if [[ -x "$rootfs/usr/sbin/VBoxDRMClient" ]]; then
  ln -sfn /usr/sbin/VBoxDRMClient "$rootfs/usr/bin/VBoxDRMClient"
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
  ln -sfn /etc/s6-linux-init/current/bin/init "$rootfs/sbin/init"
  for helper in halt poweroff reboot shutdown telinit; do
    rm -f "$rootfs/sbin/$helper"
    ln -sfn "/etc/s6-linux-init/current/bin/$helper" "$rootfs/sbin/$helper"
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
