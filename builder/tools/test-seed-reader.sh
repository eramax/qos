#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEED_READER="$PROJECT_ROOT/components/seed-reader/rootfs/usr/libexec/qos-seed-reader"

tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

root="$tmpdir/root"
seed="$tmpdir/cidata"
mkdir -p \
    "$root/etc" \
    "$root/etc/network" \
    "$root/root" \
    "$root/run" \
    "$root/sys/class/net/enp1s0" \
    "$seed"

cat > "$root/etc/shadow" <<'EOF'
root:*:19793:0:99999:7:::
EOF

cat > "$root/sys/class/net/enp1s0/address" <<'EOF'
52:54:00:12:34:56
EOF

cat > "$seed/meta-data" <<'EOF'
instance-id: 500cd427-0c3e-4dbb-880b-26c362d28233
local-hostname: sv3
EOF

cat > "$seed/network-config" <<'EOF'
version: 2
ethernets:
  uplink0:
    match:
      macaddress: "52:54:00:12:34:56"
    addresses:
      - 162.141.92.102/24
      - 2a12:bec4:1821::2/64
    gateway4: 162.141.92.1
    gateway6: 2a12:bec4:1821::1
    nameservers:
      addresses:
        - 1.1.1.1
        - 8.8.8.8
EOF

cat > "$seed/user-data" <<'EOF'
#cloud-config
timezone: Europe/Stockholm
manage_resolv_conf: true
resolv_conf:
  nameservers:
    - 9.9.9.9
users:
  - name: root
    ssh-authorized-keys:
      - ssh-rsa AAAATEST seed-key
    hashed_passwd: $6$hash$seed
bootcmd:
  - ip -6 route add default via 2a12:bec4:1821::1
EOF

QOS_SEED_READER_ROOT="$root" \
QOS_SEED_READER_SEED_DIRS="$seed" \
QOS_SEED_READER_SYS_CLASS_NET="$root/sys/class/net" \
bash "$SEED_READER"

grep -q '^sv3$' "$root/etc/hostname"
grep -q '^auto enp1s0$' "$root/etc/network/interfaces"
grep -q '^iface enp1s0 inet static$' "$root/etc/network/interfaces"
grep -q '^    address 162.141.92.102/24$' "$root/etc/network/interfaces"
grep -q '^iface enp1s0 inet6 static$' "$root/etc/network/interfaces"
grep -q '^nameserver 9.9.9.9$' "$root/etc/resolv.conf"
grep -q 'AAAATEST seed-key' "$root/root/.ssh/authorized_keys"
grep -q '^\#!/bin/sh$' "$root/etc/qos/seed-bootcmd"
grep -q '^/tmp/' "$root/etc/qos/seed-source"
grep -q '^root:\$6\$hash\$seed:' "$root/etc/shadow"
test -f "$root/run/qos/seed-reader.done"

printf 'seed-reader fixture test: PASS\n'
