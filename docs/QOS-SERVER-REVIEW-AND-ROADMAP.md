# QOS Server Profile: Comprehensive Review & Roadmap

> Date: 2026-05-22
> Status: Draft / Brainstorming
> Scope: Current state analysis, improvement ideas, Alpine→Void migration implications

---

## Table of Contents

1. [Current State Assessment](#1-current-state-assessment)
2. [What Makes a Great Server Distro](#2-what-makes-a-great-server-distro)
3. [Improvement Categories](#3-improvement-categories)
   - [3.1 Kernel Configuration](#31-kernel-configuration)
   - [3.2 Package Ecosystem](#32-package-ecosystem)
   - [3.3 Security Hardening](#33-security-hardening)
   - [3.4 s6 & Init System](#34-s6--init-system)
   - [3.5 Core Utilities](#35-core-utilities)
   - [3.6 Monitoring & Observability](#36-monitoring--observability)
   - [3.7 Storage & Filesystems](#37-storage--filesystems)
   - [3.8 Networking & Firewall](#38-networking--firewall)
   - [3.9 Build System & Reproducibility](#39-build-system--reproducibility)
4. [Alpine → Void Migration Analysis](#4-alpine--void-migration-analysis)
5. [Recommended Components & Packages](#5-recommended-components--packages)
6. [Implementation Phases](#6-implementation-phases)
7. [Appendix: Research Sources](#7-appendix-research-sources)

---

## 1. Current State Assessment

### 1.1 What Works Well

| Area | Rating | Notes |
|------|--------|-------|
| **Init system (s6)** | ★★★★★ | Already using s6 + s6-rc. Best-in-class supervision, minimal footprint, deterministic. |
| **Immutable rootfs** | ★★★★★ | Overlayfs lower + A/B update slots. Excellent for atomic updates and rollback. |
| **Size footprint** | ★★★★★ | Sub-64MB ISO, ~50MB RAM. Unbeatable for the feature set. |
| **Profile system** | ★★★★☆ | YAML-based composition with inheritance is clean and extensible. |
| **Seed reader** | ★★★★☆ | Cloud-init compatible provisioning without cloud-init bloat. |
| **BootISO / kexec** | ★★★★☆ | Boot ISO from running system without firmware reboot. |
| **K3s integration** | ★★★☆☆ | Works but k3s binary downloaded at runtime. |
| **Package management** | ★★★☆☆ | `apk.static --usermode` works but is Alpine-specific. |
| **Security hardening** | ★★★☆☆ | Basic LSM + sysctl exists but incomplete for server workloads. |
| **Monitoring** | ★☆☆☆☆ | Only syslog + btop. No metrics, no alerting. |
| **Core utilities** | ★★☆☆☆ | Busybox-only. Server ops need GNU coreutils/findutils. |
| **Time sync** | ★☆☆☆☆ | No NTP client configured. Critical for server workloads. |
| **Kernel config** | ★★★☆☆ | Good minimal config but missing server-critical features. |

### 1.2 Current Package Inventory (Server Profile)

**Total: ~32 explicitly declared packages + auto-dependencies.**

| Category | Packages | Notes |
|----------|----------|-------|
| Base OS | musl, busybox, alpine-baselayout, alpine-keys, apk-tools | Minimal C library + coreutils via busybox |
| Init | s6-linux-init, s6-portable-utils, s6-rc, execline | Full s6 stack |
| Networking | ifupdown-ng, dropbear, dropbear-scp, curl, iproute2 | Basic DHCP + SSH + routing |
| Security | nftables | Firewall only. No fail2ban, no auditd |
| Storage | e2fsprogs, e2fsprogs-extra, dosfstools, sgdisk, mtools | EXT4 + EFI tools only |
| Container | k9s, cni-plugins, conntrack-tools, iptables, iptables-legacy | k3s support |
| Tools | sudo, htop, btop, jq, yq, kexec-tools, lz4, py3-pip | Minimal admin toolbox |
| System | dcron, ca-certificates, tzdata, gcompat | Cron + TLS + timezone |
| Guest | qemu-guest-agent | VM integration |

### 1.3 Critical Gaps

1. **No time synchronization** — Servers require accurate time for TLS, logging, k8s, and auth protocols.
2. **No automatic security updates** — No mechanism for patching the running system.
3. **No file integrity monitoring** — No AIDE, tripwire, or similar.
4. **No intrusion detection** — No fail2ban, no OSSEC/Wazuh, no auditd rules.
5. **No monitoring/observability** — No Prometheus node_exporter, no metrics.
6. **No log rotation** — Busybox syslogd doesn't rotate; logs grow unbounded.
7. **No backup tooling** — No rsync, no restic, no snapshot management.
8. **No performance profiling** — perf, bpftool, strace missing at kernel level.
9. **No filesystem diversity** — EXT4 only. No XFS, Btrfs, ZFS.
10. **No virtualization host support** — KVM, VFIO, IOMMU all disabled in kernel.
11. **Busybox coreutils** — Limited functionality; many server scripts expect GNU semantics.
12. **No DNS caching** — dns component is declared but essentially empty.

---

## 2. What Makes a Great Server Distro

Research across 2026 server landscapes (Flatcar, Fedora CoreOS, Ubuntu Core, Alpine, Void):

### 2.1 Non-Negotiables for Production Servers

```
1. Immutable root filesystem with atomic updates  ← QOS has this ✓
2. Minimal attack surface                          ← QOS has this ✓
3. Time synchronization (NTP)                      ← MISSING ✗
4. Automatic security patching                     ← MISSING ✗
5. SSH key-only + fail2ban                         ← Partial (no fail2ban)
6. Firewall with default-deny                      ← QOS has nftables ✓
7. Centralized logging                             ← Basic syslog only
8. Monitoring + metrics                            ← MISSING ✗
9. File integrity monitoring                       ← MISSING ✗
10. Audit logging                                  ← MISSING ✗
```

### 2.2 Competitive Landscape Comparison

| Feature | QOS Server | Flatcar | Fedora CoreOS | Alpine | Void |
|---------|------------|---------|---------------|--------|------|
| Init system | s6 | systemd | systemd | OpenRC | runit |
| Immutable root | ✓ overlayfs | ✓ dm-verity | ✓ ostree | ✗ | ✗ |
| A/B updates | ✓ | ✓ | ✓ | ✗ | ✗ |
| Size (base RAM) | ~50MB | ~220MB | ~200MB | ~85MB | ~120MB |
| Container-native | Partial (k3s) | Docker | Podman | Manual | Manual |
| C library | musl | glibc | glibc | musl | musl/glibc |
| Cloud-init | Custom seed-reader | Ignition | Ignition | Manual | Manual |
| Kernel hardening | Basic | Moderate | Moderate | Good | Basic |
| CPU (latest kernel) | Custom | Custom | Custom | Custom | Custom |
| Patching model | Rebuild ISO | auto-update | rpm-ostree | apk upgrade | xbps update |
| Multi-arch | x86_64 only | x86_64+arm64 | x86_64+arm64 | x86_64+arm64 | x86_64+arm64 |

### 2.3 The QOS Advantage

QOS's **unique differentiator** is its **s6 init + overlayfs immutability + sub-64MB ISO**. No other distro comes close on resource efficiency while providing container orchestration, A/B updates, and cloud-init provisioning. However, QOS is missing critical server infrastructure that prevents it from being production-ready.

---

## 3. Improvement Categories

### 3.1 Kernel Configuration

#### Currently Missing (Must-Add for Server)

| Feature | Kernel Config | Priority | Rationale |
|---------|--------------|----------|-----------|
| **XFS support** | `CONFIG_XFS_FS=y/m` | HIGH | Standard for k8s storage, DB workloads, large disks. |
| **Btrfs support** | `CONFIG_BTRFS_FS=y/m` | HIGH | Snapshots, subvolumes, compression. Valuable for state partition. |
| **KVM host** | `CONFIG_KVM=y`, `CONFIG_KVM_INTEL/AMD=y` | HIGH | The server should be able to host VMs. |
| **VFIO + IOMMU** | `CONFIG_VFIO=y`, `CONFIG_IOMMU_SUPPORT=y` | HIGH | PCI passthrough, device assignment for VMs. |
| **BPF JIT** | `CONFIG_BPF_JIT=y` | HIGH | eBPF programs (Cilium, tracee, bpftrace) need JIT for performance. |
| **BPF Type Format** | `CONFIG_DEBUG_INFO_BTF=y` | HIGH | Required by Cilium, Falco, bpftrace, modern observability tools. |
| **Perf events** | `CONFIG_PERF_EVENTS=y` | MEDIUM | Performance profiling, flame graphs, production debugging. |
| **IP sets** | `CONFIG_IP_SET=y`, `CONFIG_IP_SET_HASH_*` | MEDIUM | Efficient large firewall rule sets. |
| **Traffic control** | `CONFIG_NET_SCH_*`, `CONFIG_NET_CLS_*` | MEDIUM | QoS, rate limiting, shaping. |
| **HugeTLB** | `CONFIG_HUGETLB=y` | MEDIUM | Large page support for databases, DPDK, JVMs. |
| **Kernel same-page merging** | `CONFIG_KSM=y` | MEDIUM | Memory dedup for VMs. |
| **Namespace cgroup freezer** | Already in k3s.conf | ✓ | Already covered. |

#### KSPP Security Hardening (Should-Add)

From the [Linux Kernel Self-Protection Project](https://kspp.github.io/Recommended_Settings.html) and Cloudflare's production kernel:

| Config | Effect |
|--------|--------|
| `CONFIG_STACKLEAK=y` | Clears kernel stack on syscall return — prevents stack leak |
| `CONFIG_SLAB_MERGE_DEFAULT=n` | Disable slab merging — harder to exploit heap overflows |
| `CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y` | Zero-initialize heap allocations |
| `CONFIG_INIT_ON_FREE_DEFAULT_ON=y` | Clear freed pages |
| `CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=y` | Randomize kernel stack offset on syscall |
| `CONFIG_HARDENED_USERCOPY=y` | Whitelist-based usercopy bounds checking |
| `CONFIG_SHUFFLE_PAGE_ALLOCATOR=y` | Randomize page allocator freelist |
| `CONFIG_KFENCE=y` | Low-overhead memory error detection (production-safe KASAN alternative) |
| `CONFIG_PANIC_ON_OOPS=y` | Reboot immediately on kernel Oops |
| `CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y` | Lockdown LSM integrity mode |
| `CONFIG_MODULE_SIG_FORCE=y` | Require signed kernel modules |
| `CONFIG_KEXEC_SIG_FORCE=y` | Require signed kexec images |
| `CONFIG_SECURITY_DMESG_RESTRICT=y` | Restrict dmesg to root by default |
| `CONFIG_GCC_PLUGIN_RANDSTRUCT=y` | Randomize kernel data structure layout |

**Trade-off note:** KSPP hardening has a performance cost. These should be configurable per-profile (server vs desktop).

#### Kernel Config Strategy Recommendation

**Current approach (base + fragments):** Good for modularity. But server needs a dedicated `server-secure.conf` fragment with:

```
server-kernel.conf:
  - KVM + VFIO + IOMMU
  - XFS + Btrfs
  - BPF JIT + BTF
  - Perf events + IP sets + traffic control
  - HugeTLB + KSM
  - KSPP hardening (LOCK_DOWN, STACKLEAK, SLAB_MERGE=n, etc.)
  - Module signing + kexec signing
```

**Keep disabled for server (no change):**
- Sound, USB HID, Bluetooth, Wi-Fi, GPU drivers — irrelevant for headless server
- Debug features (FTRACE, KASAN, LOCKDEP, DEBUG_INFO) — production safety

### 3.2 Package Ecosystem

#### Core Server Packages to Add

| Package | s6 Service | Priority | Purpose |
|---------|-----------|----------|---------|
| **chrony** | longrun | CRITICAL | NTP client + server. Replaces missing time sync. |
| **fail2ban** | longrun | HIGH | SSH brute-force protection. |
| **rsync** | — | HIGH | Backup, file transfer, deployment. |
| **logrotate** | cron/dcron | HIGH | Log rotation prevents disk-full from logs. |
| **strace / ltrace** | — | MEDIUM | System call tracing for debugging. |
| **tcpdump** | — | MEDIUM | Network packet capture for debugging. |
| **mtr** | — | MEDIUM | Network diagnostics (traceroute + ping). |
| **bind-tools** (dig, nslookup) | — | MEDIUM | DNS troubleshooting. |
| **auditd / audit** | longrun | HIGH | Security audit logging (CIS compliance). |
| **acpid** | longrun | MEDIUM | ACPI events (power button, lid) for bare metal. |
| **smartmontools** | longrun | MEDIUM | Disk health monitoring (S.M.A.R.T.). |
| **lsof** | — | LOW | List open files (debugging). |
| **iotop / iostat (sysstat)** | — | LOW | I/O monitoring. |
| **ncdu / du / df** | — | LOW | Disk usage analysis. |
| **ethtool** | — | MEDIUM | NIC diagnostics and tuning. |

#### Suggested New QOS Components

```
components/
  server-core/          ← Meta-component for all server essentials
    - depends_on: chrony, fail2ban, audit, smartmontools, logrotate
  server-monitoring/    ← Prometheus node_exporter + basic dashboard
  server-storage/       ← Btrfs/XFS tools, snapshot management
  docker/               ← Docker CE (alternative to k3s for some workloads)
  containerd/           ← containerd + nerdctl (standalone container runtime)
  postgres/             ← PostgreSQL server
  redis/                ← Redis cache
  nginx/                ← Nginx web server / reverse proxy
  mariadb/              ← MariaDB database
  tarpit/               ← Slowloris-style SSH tarpit for anti-brute-force
  wireguard/            ← WireGuard VPN server
  tailscale/            ← Tailscale mesh VPN (if available on target distro)
```

### 3.3 Security Hardening

#### sysctl Hardening (Production Server Baseline)

Based on Cloudflare, ESnet, and CIS benchmark recommendations:

```ini
# /etc/sysctl.d/99-qos-server.conf

# ── KERNEL HARDENING ─────────────────────────────
kernel.randomize_va_space = 2        # Full ASLR
kernel.kptr_restrict = 2             # Hide kernel pointers
kernel.dmesg_restrict = 1            # Restrict dmesg to root
kernel.core_uses_pid = 1             # Core dumps include PID
kernel.yama.ptrace_scope = 2         # Restrict ptrace to CAP_SYS_PTRACE
kernel.unprivileged_userns_clone = 0 # Disable unpriv user namespaces
kernel.panic = 10                    # Reboot 10s after panic
kernel.sysrq = 0                     # Disable SysRq

# ── NETWORK HARDENING ────────────────────────────
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1             # Protect against time-wait assassination

# ── PERFORMANCE TUNING ───────────────────────────
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fastopen = 3
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1

# ── MEMORY ───────────────────────────────────────
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.max_map_count = 1048576

# ── FILESYSTEM ────────────────────────────────────
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 256
fs.aio-max-nr = 1048576
fs.suid_dumpable = 0

# ── NETFILTER ─────────────────────────────────────
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
```

#### SSH Hardening

Current dropbear config is reasonable but needs:
- Key-only auth enforced (`-g` is already set, good)
- Idle timeout (already 300s via `-I 300`)
- Max auth tries (set via `-T 3`)
- **Whitelist specific users** (`AllowUsers` via config)
- **Bind to non-standard port** (optional, security-by-obscurity)

#### File Integrity Monitoring

AIDE (Advanced Intrusion Detection Environment) or tripwire:
- Component `aide` that installs + initializes DB on first boot
- Daily check via dcron/s6 timer
- Alert via syslog

#### Auditd Rules (CIS Benchmark Base)

```sh
# /etc/audit/rules.d/99-qos-server.rules
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/ssh/ -p wa -k sshd
-w /var/log/ -p wa -k logfiles
-a exit,always -F arch=b64 -S execve -k cmdline
```

### 3.4 s6 & Init System

#### Current State Assessment

QOS already uses s6 + s6-rc correctly. This is a **strength, not a weakness**. The s6 stack is:

- **s6-linux-init** — PID 1, mounts tmpfs, runs rc.init, execs into s6-svscan
- **s6-svscan** — Service scanner, supervises all services
- **s6-supervise** — Per-service supervision with auto-restart
- **s6-rc** — Service manager with dependency resolution, bundles

#### Comparison: s6 vs Alternatives for Server

| Aspect | s6 | runit (Void) | OpenRC (Alpine) | systemd |
|--------|-----|-------------|-----------------|---------|
| Codebase size | ~10K LOC | ~5K LOC | ~30K LOC | ~1.3M LOC |
| Memory usage | ~2MB | ~2MB | ~4MB | ~40MB+ |
| Service supervision | ✓ auto-restart | ✓ auto-restart | Partial | ✓ |
| Dependency resolution | ✓ (s6-rc) | Manual | ✓ | ✓ |
| Parallel startup | ✓ | ✓ | Optional | ✓ |
| cgroups integration | Manual | None | None | Built-in |
| Logging | svlogd (external) | svlogd (external) | External | journald (built-in) |
| Learning curve | Moderate | Low | Low | Moderate |
| Server suitability | ★★★★★ | ★★★★☆ | ★★★☆☆ | ★★★★☆ |

**Verdict:** s6 is the **best choice** for QOS server. It has the smallest footprint, best supervision model, and s6-rc provides proper dependency management. No change needed.

#### s6 Improvements for Server

1. **add svlogd** — The logging daemon from s6 suite. Already available via s6-portable-utils. Rotates logs automatically, handles disk limits. Replace busybox syslogd + klogd with s6's svlogd for supervised, rotation-aware logging.

2. **Component: s6-log** — New component providing proper log rotation configuration via svlogd:
   ```
   /etc/s6/service-tree/syslogd/
     run          # runs s6-svlogd -tt /var/log/messages
     log/run      # s6-log logger service
   ```

3. **Service dependency graph** — Current s6-rc usage is minimal (only cloud-init and mdev-coldplug declare dependencies). For server, formalize:
   ```
   networking → seed-reader
   k3s → networking, nftables, zram
   chronyd → networking
   fail2ban → networking, dropbear
   ```

4. **Health check scripts** — s6 supports `./check` scripts for readiness verification. Add readiness probes for:
   - `dropbear/check` — test SSH port is listening
   - `networking/check` — test default route is up
   - `k3s/check` — test kube API is responding

5. **User services** — s6 supports per-user service directories via `s6-svscan` in user context. Enable for multi-user desktop, skip for server.

### 3.5 Core Utilities

#### Current Problem: Busybox-Only

QOS relies entirely on busybox for coreutils. This is fine for embedded/resource-constrained, but problematic for server:

| Tool | Busybox Limitation | Server Impact |
|------|-------------------|---------------|
| `cp`, `mv`, `rm` | No `--backup`, no `-v` progress | Script compatibility |
| `find` | No `-printf`, no `-exec +` | Many scripts fail |
| `grep` | No `-P` (perl regex), limited `-o` | Compatibility issues |
| `sed` | Limited `-r` vs `-E` | Regex differences |
| `awk` | Limited to original awk, not gawk | Complex scripts fail |
| `ps` `top` `watch` | Minimal output | Debugging harder |
| `wc` `cut` `sort` | Missing options | Pipeline issues |

#### Solution: GNU coreutils component

Create `components/gnu-coreutils/` that installs:
- `coreutils` — full GNU coreutils (or `coreutils-single`)
- `findutils` — GNU find, xargs, locate
- `grep` — GNU grep with `-P`
- `sed` — GNU sed
- `gawk` — GNU awk
- `diffutils` — GNU diff

**Keep busybox as fallback.** Busybox ash is already the shell (which is fine — busybox ash is POSIX-compliant and fast). Use GNU tools alongside, prefer GNU when available.

#### Shell: ash vs bash

**Recommendation: Keep ash as default, add bash as optional.**

- ash is faster, smaller, and POSIX-compliant. Perfect for system scripts.
- bash is needed for many user/admin scripts, especially k8s tooling.
- The shebang line determines which shell is used, so both can coexist.
- Add `bash` package to server profile (negligible size cost ~1MB).

### 3.6 Monitoring & Observability

#### Current: Nothing (syslog only)

#### Proposal: Tiered Observability

**Tier 1 — Built-in (always-on, minimal cost):**

| Tool | Role | Package |
|------|------|---------|
| syslogd → svlogd | Structured log rotation | s6-portable-utils |
| dcron | Scheduled maintenance | dcron (already installed) |
| health checks | s6 probe scripts | s6 (already available) |
| SMART monitoring | Disk health | smartmontools |

**Tier 2 — Optional (enabled by profile):**

| Tool | Role | Package | Size |
|------|------|---------|------|
| node_exporter | Prometheus metrics | prometheus-node-exporter | ~30MB |
| bpftrace | Dynamic tracing | bpftrace | ~10MB |
| perf | CPU profiling | perf (kernel) | built-in |

**Tier 3 — Cluster-level (for k3s profiles):**

| Tool | Role |
|------|------|
| Metrics Server | k8s resource metrics |
| Prometheus + Grafana | Full monitoring stack (runs as k8s workloads) |
| Loki / Vector | Log aggregation |

### 3.7 Storage & Filesystems

#### Current: EXT4-only

#### Proposal: Flexible Storage Options

**Component: server-storage**

```
depends_on:
  - xfsprogs (mkfs.xfs, xfs_repair, xfs_growfs)
  - btrfs-progs (mkfs.btrfs, btrfs subvolume/snapshot/scrub)
  - lvm2 (optional — LVM volume management)
  - mdadm (optional — software RAID)
```

**State partition proposal:**
- Current: auto-expanding state partition with EXT4
- Future: Offer Btrfs as option for state partition (subvolumes for /var, /var/lib/kubelet, /var/log, /var/lib/postgresql)
- Snapshot-based rollback between upgrades

### 3.8 Networking & Firewall

#### Current: nftables + udhcpc + ifupdown-ng

#### Improvements:

1. **nftables hardening:**
   - Default-deny both directions
   - Rate limit SSH connections
   - Drop invalid packets
   - Log blocked traffic
   - Component `nftables-server` with opinionated production ruleset

2. **Network management:**
   - Keep ifupdown-ng for simple cases
   - Add `networkmanager` component for complex setups (bonding, VLAN, bridges)
   - NetworkManager works with s6 (Artix Linux does this)

3. **WireGuard VPN:**
   - Component `wireguard` with s6 service
   - WireGuard is in mainline kernel (needs config enabled)
   - wg-quick compatible

4. **DNS:**
   - Current `dns` component is empty/placeholder
   - Flesh out with proper stub resolver: `unbound` or `stubby` (DNS-over-TLS)
   - Keep dnsmasq option for LAN serving

### 3.9 Build System & Reproducibility

#### Current: apk.static + fakeroot

Issues:
- Tied to Alpine package repositories
- No package version pinning (uses rolling v3.23 tag)
- k3s binary downloaded at runtime (not air-gapped)
- No build attestation / SBOM

#### Recommendations:

1. **Package version pinning**
   - Pin all packages to specific versions in `component.yaml`
   - Use `resolve.sh` to emit a lockfile with sha256 hashes
   - Cache keyed on lockfile hash (not just package names)

2. **Vendor k3s binary**
   - Download k3s binary during build, embed in initramfs
   - Remove runtime download dependency
   - Enable air-gapped deployment

3. **SBOM generation**
   - Generate CycloneDX or SPDX SBOM during build
   - Store in ISO metadata
   - Enable vulnerability scanning

4. **Multi-arch foundation**
   - Abstract `apk.static` calls behind an architecture-aware function
   - Add arm64 cross-compilation support for kernel
   - Target Raspberry Pi / ARM servers (significant market)

---

## 4. Alpine → Void Migration Analysis

### 4.1 Motivation

Why would we migrate from Alpine to Void?

| Reason | Weight | Notes |
|--------|--------|-------|
| **glibc compatibility** ⬆ | HIGH | Void offers both musl and glibc variants. Server workloads (Datadog agent, New Relic, some DB drivers) fail on musl. |
| **Package availability** ⬆ | MEDIUM | Void has ~13K packages vs Alpine's ~28K. Alpine actually wins here. |
| **Rolling release** ⬆ | MEDIUM | Void is rolling (always latest). Alpine is tagged releases. Rolling is better for security patches but risks regression. |
| **Tooling familiarity** ⬆ | LOW | xbps vs apk: both are fast, apk is faster. |
| **Init system** ⬇ | CRITICAL | Void uses runit by default. QOS uses s6. This is a major conflict. |
| **Build system effort** ⬇ | HIGH | Entire build pipeline is Alpine-specific (apk.static --usermode, alpine-keys, repos). |
| **Community** ⬇ | LOW | Alpine has larger community, more docs, better container ecosystem. |
| **gcompat** ⬆ | MEDIUM | Alpine's gcompat solves most glibc compat issues. Void musl has similar challenges. |

### 4.2 The Void Migration Problem

QOS's build pipeline does **not** use the distribution's init system. QOS installs s6 as its init regardless of whether the underlying distro uses OpenRC (Alpine) or runit (Void). This means:

1. **apk vs xbps is the real issue**, not the init system.
2. The build script downloads `apk.static` and uses Alpine's package format.
3. To use Void, we'd need: `xbps-static` equivalent or a different bootstrap mechanism.
4. Void's xbps does not have a clean static mode like Alpine's `apk.static --usermode`.

### 4.3 Migration Effort Estimate

| Area | Effort | Risk |
|------|--------|------|
| Package install (apk.static → xbps) | HIGH | xbps lacks `--usermode`. Would need fakeroot + chroot hacks. |
| Repository configuration | MEDIUM | Different repo URLs, key signing |
| Package names | MEDIUM | Different names for same packages |
| s6 packages | MEDIUM | Void has s6 in repos, but names may differ |
| Kernel build | LOW | Same kernel source, just different build env |
| Rootfs scripts | LOW | Mostly busybox/sh compatible |
| Testing | HIGH | Entire package set must be re-validated |

### 4.4 Recommendation: Stay on Alpine, Add glibc Support

**Do not migrate to Void.** The effort is extremely high, risks are significant, and the benefits are marginal. Instead:

1. **Keep Alpine as the package source.**
2. **Add glibc via Alpine's community repo:** `apk add gcompat libgcc libstdc++` (partially done — gcompat is already installed).
3. **For workloads that absolutely need glibc:** Add a `glibc` component that installs Alpine's `glibc` and `glibc-bin` packages from community/apk.
4. **Container escape hatch:** If a service requires a specific glibc binary, run it in a container. This is the container-native approach anyway.

#### Rationale

```
Alpine advantages:
  ✓ apk is the fastest package manager
  ✓ Largest musl-native package repository (~28K)
  ✓ Sub-5MB base image
  ✓ Best container ecosystem integration
  ✓ Mature, predictable releases
  ✓ Active, large community
  ✓ Build pipeline already works

Void advantages (mostly negated):
  ✗ glibc option — gcompat solves this for most cases
  ✗ Rolling release — risk of regression
  ✗ runit init — QOS uses s6 anyway
  ✗ "Independence" — not a technical benefit
  ✗ Smaller community, fewer packages
```

### 4.5 The Real Alternative: Self-Hosted Package Repo

If apk's Alpine dependency is a concern, the ideal solution is:

1. **Mirror Alpine repositories** during build (already partially done via caching)
2. **Vendor critical packages** in the build tree
3. **Self-host a QOS-specific apk repository** for custom packages
4. This provides build reproducibility without changing the distribution

---

## 5. Recommended Components & Packages

### 5.1 New Components for Server Profile

```
server (extends: base)
components:
  # Existing
  - cluster-k3s
  - seed-reader
  - bootiso

  # New server essentials
  - chrony              # NTP time synchronization
  - fail2ban            # SSH brute-force prevention
  - auditd              # Security audit logging
  - logrotate           # Log rotation management
  - smartmontools       # Disk health monitoring
  - aide                # File integrity monitoring
  - wireguard           # VPN
  - gnu-coreutils       # GNU coreutils + findutils + grep + sed + gawk
  - server-monitoring   # Node exporter + basic metrics

  # Optional/composable
  - docker              # Docker CE (alternative container runtime)
  - postgres            # PostgreSQL
  - nginx               # Web server / reverse proxy
  - redis               # Cache

kernel:
  fragments:
    - server/kvm.conf
    - server/storage.conf
    - server/kspp-hardening.conf
    - server/observability.conf
```

### 5.2 Complete Package Inventory (Proposed)

```
# BASE (stays as-is)
alpine-baselayout, alpine-keys, apk-tools, busybox, ca-certificates,
musl, tzdata, curl, iproute2, sudo, py3-pip, execline,
s6-linux-init, s6-portable-utils, s6-rc, gcompat, dcron,
e2fsprogs, e2fsprogs-extra, dosfstools, sgdisk, mtools, htop,
ifupdown-ng, dropbear, dropbear-scp, nftables, qemu-guest-agent, btop

# SERVER-ADDED
chrony, fail2ban, audit, logrotate, smartmontools, rsync,
strace, tcpdump, mtr, bind-tools, ethtool, lsof,
coreutils, findutils, grep, sed, gawk,
xfsprogs, btrfs-progs,
wireguard-tools,
prometheus-node-exporter,
bash, vim, tmux, git,
aide, aide-conf,
unzip, p7zip,
```

## 6. Implementation Phases

### Phase 1: Foundation (2-3 weeks)

```
[ ] kernel: Add XFS, Btrfs, KVM, VFIO, IOMMU configs
[ ] kernel: Add BPF JIT + BTF
[ ] kernel: Add KSPP hardening (STACKLEAK, SLAB_MERGE=n, INIT_ON_ALLOC, etc.)
[ ] kernel: Add perf events, IP sets, traffic control
[ ] kernel: Add hugepage support
[ ] component: chrony — NTP service with s6 supervision
[ ] component: gnu-coreutils — GNU tools alongside busybox
[ ] component: logrotate — log rotation config + dcron job
```

### Phase 2: Security (2-3 weeks)

```
[ ] component: fail2ban — SSH brute-force protection
[ ] component: auditd — CIS baseline audit rules
[ ] component: aide — File integrity monitoring
[ ] sysctl: 99-qos-server.conf — production hardening
[ ] nftables: default-deny, rate-limited SSH, conntrack tuning
[ ] dropbear: key-only enforcement, max-auth-tries
```

### Phase 3: Observability (2 weeks)

```
[ ] component: smartmontools — disk health monitoring + dcron check
[ ] component: server-monitoring — prometheus node_exporter
[ ] s6: svlogd replacement for syslogd + klogd
[ ] s6: readiness checks for critical services
[ ] dcron: periodic maintenance jobs (logrotate, AIDE check, SMART check)
```

### Phase 4: Storage & Container Runtimes (2-3 weeks)

```
[ ] component: xfsprogs, btrfs-progs
[ ] state partition: Btrfs option with subvolumes
[ ] component: docker — Docker CE as alternative to k3s
[ ] k3s: vendor binary in build (remove runtime download)
[ ] k3s: offline / air-gapped mode
```

### Phase 5: Network & VPN (1-2 weeks)

```
[ ] component: wireguard — WireGuard VPN + s6 service
[ ] nftables: complete production ruleset
[ ] component: unbound — DNS stub resolver (TLS capable)
```

### Phase 6: Build System & Polish (2-3 weeks)

```
[ ] package pinning: lockfile with sha256 hashes
[ ] SBOM generation during build
[ ] k3s binary vendored in build
[ ] os-release: update ID to qos (not alpine)
[ ] documentation: server deployment guide
[ ] benchmarks: resource usage, boot time, security score
```

---

## 7. Appendix: Research Sources

### Web Research Conducted (2026-05-22)

1. **Best minimal Linux server distros 2026** — Flatcar, Fedora CoreOS, Ubuntu Core, Alpine, Void benchmarked against memory, boot time, telemetry, and security.
2. **Alpine vs Void comparison** — Package counts (28K vs 13K), init systems (OpenRC vs runit), package managers (apk vs xbps), build system feasibility.
3. **s6 vs runit vs systemd** — Memory footprint (2MB vs 2MB vs 40MB+), supervision models, dependency management, server suitability.
4. **Kernel config for servers** — KSPP hardening recommendations from Cloudflare, ESnet, kernel.org LTS 6.12 guidance.
5. **Production server hardening** — CIS benchmarks, sysctl tuning, SSH hardening, firewall defaults, audit rules.
6. **Server monitoring & observability** — Prometheus node_exporter, bpftrace, perf, SMART monitoring.
7. **Ubuntu Core 26** — Chisel-based builds, snap-delta updates, TPM-sealed encryption, immutable design patterns.

### Key Takeaways from Research

- **s6 is the right choice** — Keep it. It's the most resource-efficient, deterministic init with excellent supervision.
- **Alpine should stay** — Migrating to Void is high-effort, high-risk, and low-benefit. The glibc gap is solvable via gcompat + containers.
- **KSPP hardening is table stakes** — Cloudflare, Canonical, and Red Hat all ship production kernels with similar hardening.
- **Time sync is non-negotiable** — Every production server checklist starts with chrony/NTP. Its absence is the #1 gap.
- **Observability must be default** — Node_exporter + SMART + basic logging should be always-on. Full monitoring is optional.
- **GNU coreutils are expected** — Every server operator expects `find`, `grep -P`, `sed -r`, `awk` to work as documented.
- **Package pinning is critical** — Reproducible builds require version-pinned dependencies, not rolling tags.

---

*End of document. This is a living design document. All implementation should follow the standard YAML component pattern and add features as composable components.*
