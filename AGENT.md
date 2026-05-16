# QOS Project Knowledge Base

This document captures everything learned about the QOS project — structure, build/deploy flow, debugging techniques, and operational recipes. It is a living reference to avoid rediscovering the project each session.

## Project Overview

QOS is a minimal, reproducible Linux distribution built on Alpine Linux. Key traits:
- **Init**: s6-linux-init → s6 → s6-rc (dependency-driven supervision)
- **Rootfs**: overlayfs (squashfs lower layer read-only, tmpfs upper layer ephemeral on live CD; state partition bound over /var and /home when installed)
- **C library**: musl (not glibc)
- **Shell**: busybox ash (avoid bashisms in rootfs scripts)
- **Kernel**: custom compiled, UEFI-only, no BIOS/MBR
- **Bootloader**: Limine (UEFI)
- **Disk layout**: GPT — EFI partition + root-a + root-b + state (auto-expands)
- **ISO target**: sub-64MB (base), grows with components
- **RAM target**: sub-40MB at runtime

## Key Terminology

| Term | Meaning |
|------|---------|
| **live CD** | System booted from ISO; rootfs is squashfs + tmpfs overlay (ephemeral, lost on reboot) |
| **installed** | System booted from disk; /var and /home are bind-mounted from the state partition (ext4, persistent) |
| **state partition** | ext4 partition (label: `qos-state`) mounted at /state during init, then bind-mounted to /var and /home |
| **seed/cidata** | ISO9660 or raw block device with `meta-data`, `user-data`, `network-config` files; processed by seed-reader |
| **bootiso** | kexec-based live-CD boot without firmware reboot; mounts ISO, extracts kernel+initrd+rootfs.sfs, kexecs |
| **s6 service-tree** | `/etc/s6/service-tree/` — source directory for s6 services; linked into `/run/service/` at boot |
| **s6 service-def** | Service definitions stored outside the tree (e.g., under `/usr/share/qos/s6/`); only activated when explicitly installed |

## Build System

### Pipeline (6 stages)

```
builder/build.sh
  ├── 01-rootfs     — Alpine package install + rootfs layout
  ├── 02-kernel     — Custom Linux kernel compile
  ├── 03-initramfs  — Early boot environment (overlayfs mount, switch_root)
  ├── 04-limine     — UEFI Limine bootloader
  ├── 05-image      — GPT disk image
  └── 06-iso        — ISO creation (squashfs rootfs.sfs, initramfs-live.img, ESP)
```

`builder/resolve.sh` (Python) reads the profile YAML, resolves component dependencies, generates a merged kernel config, and builds the package list **before** the pipeline runs.

### Build Commands

```sh
make server           # Build server profile (what we use)
make full             # Full build: rootfs → kernel → initramfs → bookloader → image → ISO
make clean            # Full clean (kernel + rootfs + bootloader cache)
make clean-rootfs     # Clear rootfs cache only (use when only rootfs files changed, not kernel config)
make kernel           # Rebuild kernel only
```

The kernel is cached by config hash. If you only change `component.yaml`, `rootfs/` files, or s6 scripts, use `make clean-rootfs` to avoid a full kernel rebuild (~5 min).

### Profile System (`profiles/*.yaml`)

```yaml
name: server
extends: base
kernel:
  fragments:
    - components/bootiso/kernel/kexec.conf
    - components/cluster-k3s/kernel/k3s.conf
components:
  - cluster-k3s
  - seed-reader
  - bootiso
```

Profiles compose components. `base` provides minimal core. `server` adds server-specific components.

### Component System (`components/*/`)

Each component directory:
```
components/<name>/
  component.yaml     # packages, depends_on, other metadata
  rootfs/            # files copied verbatim into target rootfs (preserving paths)
  s6/                # s6 service definitions
    service-tree/    # auto-registered at boot (copied to /etc/s6/service-tree/)
    s6-rc.d/         # s6-rc dependency bundles
  kernel/            # kernel config fragment (*.conf)
```

**service-tree vs service-def**: Files under `s6/service-tree/` are auto-installed into s6 supervision at boot. To have a service that is only activated on demand, store the definition under a different path (e.g., `rootfs/usr/share/qos/s6/`) and have a CLI command install it into `/etc/s6/service-tree/` and `/run/service/`.

### Adding a New Component

1. Create `components/<name>/component.yaml` with `packages:` and optional `depends_on:`
2. Add any rootfs files to `components/<name>/rootfs/`
3. If it runs a service, add `components/<name>/s6/service-tree/<svcname>/run` (or `service-def/` for on-demand services)
4. Reference it in the profile: `profiles/server.yaml` under `components:` or `kernel.fragments:`

## Kernel

- Base config: `components/kernel/kernel/x86_64.config`
- Fragment configs: `components/<name>/kernel/*.conf`
- `resolve.sh` concatenates base + fragments into a single file
- Build script runs `merge_config.sh` then `make olddefconfig` (which resolves dependencies and may drop options)
- Kernel source cached at `build/cache/kernel/linux-<version>/`
- Kernel build output at `build/kernel/build/`

**Important**: `make olddefconfig` can silently drop config options if dependencies aren't met. Always grep the final `.config` (`build/kernel/build/.config`) to verify options survived. If an option is present in the resolved fragment but missing from `.config`, check the Kconfig dependency chain in the kernel source.

### Checking Kernel Config Dependencies

```sh
# Find the Kconfig definition for an option
grep -A10 'config IP_NF_NAT' build/cache/kernel/linux-*/net/ipv4/netfilter/Kconfig

# Check what's actually in the built config
grep 'CONFIG_IP_NF_NAT' build/kernel/build/.config

# Check the resolved (pre-olddefconfig) config  
grep 'CONFIG_IP_NF_NAT' build/generated/profiles/server/kernel/x86_64.config
```

## Init System (s6)

- PID 1: `s6-linux-init` → `s6-svscan` on `/run/service/`
- Services are either `longrun` (daemons) or `oneshot` (run once, then stay "up" with `exec sleep 2147483647`)
- Service run scripts are simple shell scripts; must `exec` the daemon for longrun services
- To add a new service: place `run` script under component's `s6/service-tree/<name>/`
- To make a service only start when enabled: store under a different dir, have CLI copy it to `/run/service/` and `/etc/s6/service-tree/`

### s6 Commands

```sh
s6-svc -u /run/service/<name>    # send SIGUP (up)
s6-svc -d /run/service/<name>    # send SIGTERM (down)  
s6-svc -r /run/service/<name>    # restart (SIGTERM + SIGCONT)
```

## Package Management (APK)

- Packages listed in `components/<name>/component.yaml` under `packages:`
- `components/apk/packages.system` has system-wide packages
- Build cache is keyed on profile + package hash; changing packages invalidates rootfs cache → run `make clean-rootfs`
- On live CD, `/etc/apk` is on read-only squashfs; `apk add` works but may warn about db write failures (packages still install into the tmpfs overlay)

## Live CD vs Installed System

| Aspect | Live CD | Installed |
|--------|---------|-----------|
| Rootfs | squashfs + tmpfs overlay (ephemeral) | ext4 lower + state/overlay upper (persistent) |
| /var | tmpfs overlay | bind-mounted from state partition |
| /home | tmpfs overlay | bind-mounted from state partition |
| /mnt/qos-state | must mount manually (`mount /dev/vda3 /mnt/qos-state`) | state partition already mounted at /state (hidden), /var and /home bound |
| apk | installs to tmpfs (lost on reboot) | installs to overlay upper (persists) |

### Detecting Live CD vs Installed

```sh
# Check cmdline
grep -q 'boot=live' /proc/cmdline && echo "live" || echo "installed"

# Check for /home/<user> (exists on both but only persistent when installed)
test -d /home/emo && echo "has home dir"
```

## initramfs and Boot Flow

### Installed Boot (`03-initramfs/build-initramfs.sh`)

1. Kernel loads initramfs.img (lz4-compressed cpio)
2. Init script runs: mounts proc/sys/devtmpfs, resolves root and state partitions by label
3. Mounts root (squashfs or ext4) read-only, mounts state partition at /state
4. Sets up overlayfs: lowerdir=/ro-root, upperdir=/state/overlay/upper
5. Bind-mounts /state/var → /var, /state/home → /home
6. switch_root to /sysroot, exec /sbin/init (s6)

### Live CD Boot (`06-iso/build-iso.sh` — the live_init script)

1. Kernel/EFI loads from ISO; Limine boots vmlinuz + initramfs-live.img
2. Init script checks for embedded `/rootfs.sfs` in initramfs (for kexec bootiso path)
3. If not embedded, scans block devices for ISO9660 filesystem containing rootfs.sfs
4. Mounts rootfs.sfs via loopback (squashfs), sets up tmpfs overlay
5. Sets hostname to `qos-live`, stamps boot-source as `live-cdrom`
6. switch_root to /sysroot, exec /sbin/init

### bootiso (kexec-based live boot)

`components/bootiso/rootfs/usr/bin/bootiso`:
1. Mounts the ISO file via loopback
2. Finds vmlinuz and initramfs-live.img
3. Copies rootfs.sfs from ISO
4. Decompresses initramfs-live.img (lz4), appends rootfs.sfs as a separate cpio archive
5. Preserves console/earlycon/loglevel from current kernel cmdline (adds `boot=live`)
6. `kexec -l` + `kexec -e` to hand off to the new kernel

**Requires**: `kexec-tools`, `lz4`, `cpio`, kernel with `CONFIG_KEXEC=y`

## Seed Reader (Cloud-Init Replacement)

`components/seed-reader/rootfs/usr/libexec/qos-seed-reader`:
- Scans block devices for seed media (ISO9660 or raw with meta-data/user-data/network-config)
- Mounts seed, processes YAML files via `yq` (mikefarah/go version) + `jq`
- Applies: hostname, static network config (ifupdown-ng), resolv.conf, timezone, user SSH keys, password hash, bootcmd
- Writes done marker: `/run/qos/seed-reader.done`
- Network config is written to `/etc/network/interfaces` for ifupdown-ng

**Important**: On live CD, seed-reader must run BEFORE networking. The networking service waits for `seed-reader.done` marker before configuring interfaces.

### Seed Disk Format

ISO9660 filesystem (or raw block device) with these files:
```
meta-data:
  instance-id: <uuid>
  local-hostname: <hostname>

user-data (YAML):
  timezone: Europe/Stockholm
  manage_resolv_conf: true
  resolv_conf:
    nameservers:
      - 1.1.1.1
  users:
    - name: root
      ssh-authorized-keys:
        - 'ssh-rsa AAAAB3...'
      hashed_passwd: '$6$...'
  bootcmd:
    - 'command1'
    - 'command2'

network-config (YAML, version 2):
  ethernets:
    eth0:
      match:
        macaddress: 'aa:bb:cc:dd:ee:ff'
      addresses:
        - 1.2.3.4/24
      gateway4: 1.2.3.1
      nameservers:
        addresses:
          - 1.1.1.1
```

### Creating a Seed ISO

```sh
mkdir -p /tmp/seed
cat > /tmp/seed/meta-data <<'EOF'
instance-id: test-001
local-hostname: testhost
EOF
cat > /tmp/seed/user-data <<'EOF'
#cloud-config
timezone: UTC
ssh_pwauth: true
users:
  - name: root
    ssh-authorized-keys:
      - 'ssh-rsa AAAAB3...'
EOF
cat > /tmp/seed/network-config <<'EOF'
version: 2
ethernets:
  eth0:
    match:
      macaddress: '08:00:27:f0:11:25'
    addresses:
      - 10.0.2.15/24
    gateway4: 10.0.2.2
EOF
xorriso -as mkisofs -R -V cidata -o seed.iso meta-data user-data network-config
```

### Attaching Seed to VirtualBox VM

```sh
VBoxManage storagectl qos-server --name "SATA Controller" --portcount 4
VBoxManage storageattach qos-server --storagectl "SATA Controller" --port 2 --device 0 \
    --type dvddrive --medium virtualbox/qos-server/seed.iso
```

## VirtualBox VM Management

```sh
make vm-create PROFILE=server      # Create VM (once)
make vm-boot   PROFILE=server      # Start VM headless
make vm-stop   PROFILE=server      # Stop VM (graceful shutdown)
make vm-ssh    PROFILE=server      # SSH into VM
make vm-list                       # List VMs
make vm-delete PROFILE=server      # Delete VM
```

VM is named `qos-server` for server profile, `qos-desktop` for desktop.
SSH: `sshpass -p emo2500 ssh -o StrictHostKeyChecking=no -p 2222 emo@localhost`

VM serial log: `virtualbox/qos-server/serial.log`

### VM Network

- NAT networking; port 2222 forwarded to guest port 22
- Guest gets IP via DHCP (10.0.2.15/24) or static config from seed
- Default gateway: 10.0.2.2

## VPS Deployment (bootiso flow)

```sh
make vps-upload-iso HOST=<ip>     # Upload ISO to VPS
make vps-run-iso   HOST=<ip>      # Run uploaded ISO (kexec boot)
make vps-bootiso   HOST=<ip>      # Upload + run combined
```

The vps-bootiso.sh script:
1. Checks VPS connectivity via SSH
2. Detects if VPS runs installed QOS (has /home/emo) → stores ISO at `/home/emo/qos-server.iso` (persistent)
3. If live CD, mounts state partition at `/mnt/qos-state` and stores ISO there
4. Verifies checksum after upload
5. For run: executes remote `bootiso` command, waits for VPS to return with new IP

SSH pattern: `sshpass -p <pass> ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null user@host`

## Development Tips

### Shell Compatibility

- Target shell is **busybox ash**, not bash
- No bashisms: no arrays `()`, no `[[ ]]` (use `[ ]`), no `$RANDOM`, no `${var^}`, no `<<<`
- Use `printf` instead of `echo -e`
- Use `$(seq 1 10)` not `{1..10}`
- `set -eu` at top of all scripts (but `-o pipefail` not in busybox ash)
- Pipes create subshells in ash; variable assignments inside `while read` loops don't survive

### Checking Busybox Applet Availability

```sh
busybox --list          # List all available applets
which <cmd>             # Check if applet is enabled
```

### Reading the Serial Console

The VM serial console writes to `virtualbox/qos-server/serial.log`. Useful for debugging boot issues when SSH isn't available.

```sh
tail -f virtualbox/qos-server/serial.log
```

### Debugging Boot Issues

- VGA console + serial console both enabled (`console=tty0 console=ttyS0,115200n8`)
- Initramfs scripts redirect output to `/dev/console`
- If rootfs.sfs not found, init script drops to emergency shell (visible on serial)

### Checking What's Running

```sh
ps aux                     # Limited on busybox
cat /proc/mounts           # See all mounts
cat /proc/cmdline          # See kernel boot params
cat /etc/qos/version       # See build version
cat /etc/qos/boot-source   # See if live-cdrom or installed-disk
```

### Path Differences (Alpine)

- CNI plugins: `/usr/libexec/cni/` (not `/opt/cni/bin/` like standard k3s)
- iptables: legacy at `/usr/sbin/iptables-legacy`, nftables at `/sbin/iptables`
- `nohup` may not be available (use `&` + background)
- `pgrep` may not be available (use `ps aux | grep`)

## File Locations

| Path | Purpose |
|------|---------|
| `components/<name>/component.yaml` | Component metadata and packages |
| `components/<name>/rootfs/` | Files copied to target rootfs |
| `components/<name>/s6/service-tree/` | Auto-registered s6 services |
| `components/<name>/kernel/*.conf` | Kernel config fragments |
| `profiles/server.yaml` | Server profile definition |
| `builder/pipeline/02-kernel/build-kernel.sh` | Kernel build logic |
| `builder/pipeline/03-initrmd/build-initramfs.sh` | Installed-system initramfs |
| `builder/pipeline/06-iso/build-iso.sh` | ISO + live initramfs + rootfs.sfs |
| `builder/tools/vps-bootiso.sh` | VPS upload and kexec boot |
| `builder/tools/vm-manage.sh` | VirtualBox VM management |
| `builder/tools/bootiso-remote.sh` | Alternative remote bootiso tool |
| `components/bootiso/rootfs/usr/bin/bootiso` | kexec ISO boot script |
| `components/seed-reader/rootfs/usr/libexec/qos-seed-reader` | Seed data processor |
| `components/qos/rootfs/usr/bin/qos` | Umbrella CLI |
| `components/qos/rootfs/usr/bin/qos-cluster` | Cluster management CLI |
| `build/kernel/build/.config` | Final built kernel config |
| `build/generated/profiles/server/kernel/x86_64.config` | Resolved (pre-olddefconfig) kernel config |
| `build/kernel/build/vmlinuz` | Built kernel image |
| `build/initramfs/initramfs.img` | Installed-system initramfs |
| `dist/qos-server.iso` | Output ISO |
