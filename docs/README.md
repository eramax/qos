# QOS Distro - Documentation Index

**Version:** 2.0 (Optimized Server Release)  
**Date:** 2026-04-12

---

## Quick Navigation

### 🚀 Getting Started
1. Read: **[README.md](../README.md)** - Project overview and quick start
2. Build: `make clean && make full`
3. Boot: `make qemu`
4. Verify: Follow verification steps below

### 📚 Documentation Guide

Read documents in this order:

1. **[REFACTORING-SUMMARY.md](REFACTORING-SUMMARY.md)** ⭐ START HERE
   - Complete summary of all changes
   - What was done and why
   - Results and metrics
   - Next steps

2. **[REFACTORING-AND-VERIFICATION.md](REFACTORING-AND-VERIFICATION.md)** ✅ VERIFY HERE
   - Detailed verification steps
   - What to expect for each feature
   - Troubleshooting guide
   - Verification checklist

3. **[IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md)** 🔧 IMPLEMENTATION
   - How to build and configure
   - Configuration examples
   - Hosting workflow examples
   - Capability system examples

4. **[ANALYSIS-AND-REVIEW.md](ANALYSIS-AND-REVIEW.md)** 📊 ANALYSIS
   - Complete project analysis
   - Package redundancy analysis
   - Kernel optimization strategy
   - Future roadmap

5. **[QUICK-REFERENCE.md](QUICK-REFERENCE.md)** 📖 QUICK REFERENCE
   - Common commands
   - Service management
   - Troubleshooting commands
   - File locations

---

## Document Purposes

### REFACTORING-SUMMARY.md
**Purpose:** Complete overview of what was done  
**Read if:** You want to understand all changes  
**Contains:**
- What changed (by category)
- Results and metrics
- Architecture diagrams
- Design decisions
- Known limitations
- Next steps

### REFACTORING-AND-VERIFICATION.md
**Purpose:** Verify everything works  
**Read if:** You're testing the build  
**Contains:**
- Step-by-step verification for each feature
- Expected output examples
- Pass/fail criteria
- Troubleshooting guide
- Verification checklist

### IMPLEMENTATION-GUIDE.md
**Purpose:** How to use the system  
**Read if:** You're configuring or deploying  
**Contains:**
- Build instructions
- Configuration examples
- Hosting workflow (Bun + reverse proxy)
- Capability system usage
- Clustering setup
- Performance benchmarks

### ANALYSIS-AND-REVIEW.md
**Purpose:** Deep understanding of the system  
**Read if:** You want to understand the "why"  
**Contains:**
- Package redundancy analysis
- Kernel config analysis
- Init system comparison
- Future recommendations
- Desktop/Android roadmap

### QUICK-REFERENCE.md
**Purpose:** Quick command lookup  
**Read if:** You need commands fast  
**Contains:**
- Build commands
- Boot commands
- Service management
- Monitoring commands
- Capability system commands
- Clustering commands
- Troubleshooting commands

---

## Quick Verification Steps

If you just want to verify everything works quickly:

```bash
# 1. Build (10-15 minutes)
make clean && make full

# 2. Check image size
ls -lh dist/qos-x86_64.raw
# Expected: 64M

# 3. Boot (3-5 seconds)
make qemu

# 4. SSH in (inside QEMU, find IP with `ip addr show`)
ssh root@<ip>
# Password: root

# 5. Check services
s6-rc -a list
# Expected: Core services running

# 6. Check memory
free -m
# Expected: <40MB used

# 7. Test capability system
qos-capability list
# Expected: 3 profiles shown

# 8. Test clustering
qos-cluster nodes
# Expected: This node shown

# 9. Test reverse proxy (if caddy installed)
curl http://localhost:80
# Expected: "QOS Server Running"
```

**If all pass:** ✅ System working correctly!

**If any fail:** See `docs/REFACTORING-AND-VERIFICATION.md` troubleshooting section

---

## Feature Documentation

### Capability System

**What:** Fine-grained resource and access control  
**Files:** `config/qos/capabilities/profiles/*.cap`  
**Tool:** `qos-capability`  
**Docs:** [IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md) - Section on Capability System

**Quick Start:**
```bash
qos-capability list                      # List profiles
qos-capability apply webapp webapp.cap  # Apply profile
qos-capability show webapp               # Show current limits
qos-capability test webapp               # Test enforcement
```

### Reverse Proxy

**What:** Domain hosting with automatic HTTPS  
**Files:** `config/caddy/Caddyfile`  
**Service:** `reverse-proxy` (s6 managed)  
**Docs:** [IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md) - Section on Reverse Proxy

**Quick Start:**
```bash
# Edit Caddyfile
vi /etc/caddy/Caddyfile

# Add domain routing
example.com {
    reverse_proxy localhost:3000
}

# Reload
pkill -HUP caddy

# Test
curl -H "Host: example.com" http://localhost
```

### Clustering

**What:** Node discovery and resource awareness  
**Files:** `config/qos/cluster/node.conf`  
**Service:** `cluster` (s6 managed)  
**Tool:** `qos-cluster`  
**Docs:** [IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md) - Section on Clustering

**Quick Start:**
```bash
qos-cluster status     # This node's status
qos-cluster nodes      # List cluster members
qos-cluster resources  # Show aggregated resources
qos-cluster services   # List all services
```

### Disk Expansion

**What:** Expand state partition to full disk  
**Tool:** `qos-expand`  
**Docs:** [IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md) - Section on Image Layout

**Quick Start:**
```bash
# Flash image
sudo dd if=dist/qos-x86_64.raw of=/dev/sda bs=4M status=progress

# Expand to full disk
sudo qos-expand /dev/sda
```

---

## Troubleshooting Quick Reference

### Build Issues

```bash
# Check build logs
tail -100 build/logs/build.log

# Common fix: install missing dependencies
sudo apt install build-essential bc perl help2man indent

# Retry failed step
make kernel    # If kernel failed
make rootfs    # If rootfs failed
```

### Boot Issues

```bash
# Boot with serial output to see errors
make boot

# Check QEMU logs
cat build/qemu/serial.log
```

### Service Issues

```bash
# Check service status
s6-svstat /run/service/*

# Check service logs
cat /var/log/<service>/current

# Restart service
s6-rc -u change <service>
```

### Network Issues

```bash
# Check interface
ip addr show eth0

# Manual DHCP
busybox udhcpc -i eth0 -T 5 -t 10

# Test connectivity
ping -c 3 8.8.8.8
```

### Capability Issues

```bash
# Check cgroups mounted
mount | grep cgroup2

# Check controllers
cat /sys/fs/cgroup/cgroup.controllers

# Manual test
mkdir -p /sys/fs/cgroup/test
echo "100000 100000" > /sys/fs/cgroup/test/cpu.max
```

---

## File Locations Reference

### Configuration Files

```
config/kernel/x86_64.config           - Kernel configuration
config/apk/packages.base              - Base packages
config/apk/packages.system            - System packages
config/qos/capabilities/profiles/     - Capability profiles
config/qos/cluster/node.conf          - Cluster configuration
config/caddy/Caddyfile                - Reverse proxy config
config/chrony/chrony.conf             - NTP configuration
config/image/layout-64mb.json         - Image layout definition
config/s6/service-tree/               - Service scripts
config/s6/s6-rc.d/                    - Service type definitions
```

### Runtime Files

```
/var/log/<service>/current            - Service logs
/var/lib/webapp/                      - Webapp data
/var/lib/cluster/                     - Cluster data
/etc/qos/capabilities/profiles/       - Installed capability profiles
/etc/qos/cluster/node.conf            - Installed cluster config
/etc/caddy/Caddyfile                  - Installed Caddy config
/etc/chrony/chrony.conf               - Installed Chrony config
/run/service/                         - s6 service directories
/sys/fs/cgroup/                       - Cgroups v2 hierarchy
```

### Build Artifacts

```
build/rootfs/                         - Staged root filesystem
build/kernel/vmlinuz                  - Compiled kernel
build/initramfs/initramfs.img         - Initramfs
build/boot/                           - Bootloader staging
build/image/                          - Image staging
dist/qos-x86_64.raw                   - Final 64MB image
build/build.manifest                  - Build provenance
build/logs/build.log                  - Build log
```

### Scripts

```
scripts/qos-capability.sh             - Capability management tool
scripts/qos-cluster.sh                - Cluster management tool
scripts/qos-expand.sh                 - Disk expansion tool
scripts/build-rootfs.sh               - Rootfs builder
scripts/build-kernel.sh               - Kernel builder
scripts/build-initramfs.sh            - Initramfs builder
scripts/install-services.sh           - Service installer
scripts/assemble-image.sh             - Image assembler
scripts/run-qemu.sh                   - QEMU launcher
```

---

## Common Workflows

### Workflow 1: First-Time Build & Test

```bash
# 1. Install prerequisites
sudo apt install git curl ca-certificates bash python3 jq mkosi \
  qemu-system-x86 qemu-utils squashfs-tools xorriso mtools dosfstools \
  e2fsprogs parted util-linux libarchive-tools ovmf \
  build-essential bc perl help2man indent

# 2. Build
make clean && make full

# 3. Verify image size
ls -lh dist/qos-x86_64.raw  # Should be 64M

# 4. Boot
make qemu

# 5. SSH in (get IP from QEMU console)
ssh root@<ip>
# Password: root

# 6. Check system
s6-rc -a list
free -m
df -h

# 7. Test features
qos-capability list
qos-cluster nodes
curl http://localhost:80
```

### Workflow 2: Deploy WebApp with Domain

```bash
# 1. Install bun (add to packages.system, rebuild)
# 2. SSH into QOS
ssh root@<qos-ip>

# 3. Create webapp
mkdir -p /var/lib/webapp
cd /var/lib/webapp
cat > server.ts <<'EOF'
const server = Bun.serve({
  port: 3000,
  fetch(req) {
    return new Response("Hello from my app!");
  },
});
EOF

# 4. Configure reverse proxy
cat > /etc/caddy/Caddyfile <<'EOF'
example.com {
    reverse_proxy localhost:3000
}
EOF

# 5. Restart services
pkill -HUP caddy
s6-rc -u change webapp

# 6. Test
curl -H "Host: example.com" http://localhost
```

### Workflow 3: Set Up Cluster

```bash
# Node 1
ssh root@node1
cat > /etc/qos/cluster/node.conf <<'EOF'
NODE_ID="qos-node-01"
CLUSTER_NAME="my-cluster"
EOF
qos-cluster nodes

# Node 2
ssh root@node2
cat > /etc/qos/cluster/node.conf <<'EOF'
NODE_ID="qos-node-02"
CLUSTER_NAME="my-cluster"
EOF
qos-cluster nodes
# Should show both nodes
```

### Workflow 4: Apply Capability Profile

```bash
# 1. List available profiles
qos-capability list

# 2. Apply profile to service
qos-capability apply webapp webapp.cap

# 3. Verify limits
qos-capability show webapp
# Expected: CPU quota, memory limit, PID limit

# 4. Test enforcement
qos-capability test webapp
# Expected: All checks pass
```

### Workflow 5: Flash to Real Hardware

```bash
# 1. Flash image
sudo dd if=dist/qos-x86_64.raw of=/dev/sda bs=4M status=progress

# 2. Expand to full disk
sudo qos-expand /dev/sda

# 3. Boot on hardware
# (Remove USB, boot from disk)

# 4. Verify
ssh root@<hardware-ip>
df -h  # Should show expanded /var
```

---

## Support Resources

### For Understanding
- Read: [REFACTORING-SUMMARY.md](REFACTORING-SUMMARY.md)
- Read: [ANALYSIS-AND-REVIEW.md](ANALYSIS-AND-REVIEW.md)

### For Building
- Read: [IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md) - Build section
- Run: `make clean && make full`

### For Testing
- Read: [REFACTORING-AND-VERIFICATION.md](REFACTORING-AND-VERIFICATION.md)
- Follow: Verification checklist

### For Configuration
- Read: [IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md) - Configuration examples
- Read: [QUICK-REFERENCE.md](QUICK-REFERENCE.md) - Commands

### For Troubleshooting
- Read: [REFACTORING-AND-VERIFICATION.md](REFACTORING-AND-VERIFICATION.md) - Troubleshooting section
- Check: Service logs in `/var/log/<service>/current`
- Check: Build logs in `build/logs/build.log`

---

## Version History

### v2.0 (2026-04-12) - Current
- ✅ 64MB image (down from 1GB)
- ✅ Capability-based access control
- ✅ Reverse proxy + DNS
- ✅ Cluster discovery
- ✅ Dynamic state partition
- ✅ Multicore scheduler optimization
- ✅ Microkernel-like design
- ✅ Enhanced security features

### v1.0 (Previous)
- Basic minimal Alpine distro
- UEFI boot with Limine
- s6/s6-rc supervision
- Dropbear SSH
- nftables firewall
- A/B OTA updates
- 1GB image size

---

## Quick Help

**Q: How do I build?**  
A: `make clean && make full`

**Q: How do I boot?**  
A: `make qemu`

**Q: How do I SSH in?**  
A: `ssh root@<qos-ip>` (password: root)

**Q: How do I check services?**  
A: `s6-rc -a list`

**Q: How do I check memory?**  
A: `free -m`

**Q: How do I test capabilities?**  
A: `qos-capability list`

**Q: How do I test clustering?**  
A: `qos-cluster nodes`

**Q: How do I test reverse proxy?**  
A: `curl http://localhost:80`

**Q: Image too large, what do I do?**  
A: See troubleshooting in [REFACTORING-AND-VERIFICATION.md](REFACTORING-AND-VERIFICATION.md)

**Q: Services not starting?**  
A: Check logs: `cat /var/log/<service>/current`

**Q: Need more help?**  
A: Read the full documentation starting with [REFACTORING-SUMMARY.md](REFACTORING-SUMMARY.md)

---

**End of Documentation Index**

Start with [REFACTORING-SUMMARY.md](REFACTORING-SUMMARY.md) to understand what changed, then follow [REFACTORING-AND-VERIFICATION.md](REFACTORING-AND-VERIFICATION.md) to verify everything works.
