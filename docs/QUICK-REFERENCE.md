# QOS Distro - Quick Reference Card

**Version:** 2.0 (Optimized Server Release)  
**Date:** 2026-04-12

---

## Build Commands

```bash
# Full build
make clean && make full

# Build components individually
make rootfs      # Build rootfs only
make services    # Install services into rootfs
make kernel      # Build kernel only
make initramfs   # Build initramfs only
make boot-limine # Stage bootloader
make image       # Assemble final image

# Build with logging
make build-log

# Grep build log
make build-grep
```

## Boot Commands

```bash
# Boot in QEMU (default: 1GB RAM, 2 CPU, bridged net)
make qemu

# Boot with serial output to terminal
make boot

# Smoke boot (captures serial log)
make smoke

# Boot with custom resources
QEMU_MEM=512 QEMU_CPUS=4 make qemu

# Boot with NAT networking
QEMU_NET_MODE=nat make qemu
```

## SSH Access

```bash
# SSH into QOS (default password: root)
ssh root@<qos-ip>

# SSH test (auto-installs btop)
make ssh-test
```

## Service Management

```bash
# List all services
s6-rc -a list

# Check service status
s6-svstat /run/service/*

# Start/stop service
s6-rc -u change <service>
s6-rc -d change <service>

# View service logs
cat /var/log/<service>/current

# Restart service
pkill -HUP <service>
```

## System Monitoring

```bash
# Memory usage
free -m

# Disk usage
df -h

# Process list
htop
ps aux

# Network interfaces
ip addr show

# Routing table
ip route show

# Loaded kernel modules
lsmod

# Kernel version
uname -r
```

## Capability System

```bash
# List available profiles
qos-capability list

# Apply profile to service
qos-capability apply <service> <profile.cap>

# Show current limits
qos-capability show <service>

# Test enforcement
qos-capability test <service>

# Example: Apply webapp profile
qos-capability apply webapp webapp.cap
```

## Clustering

```bash
# Show node status
qos-cluster status

# List cluster members
qos-cluster nodes

# Show cluster resources
qos-cluster resources

# List services in cluster
qos-cluster services
```

## Reverse Proxy

```bash
# Check caddy status
ps aux | grep caddy

# Test default page
curl http://localhost:80

# Test domain routing
curl -H "Host: example.com" http://localhost

# Validate config
caddy validate --config /etc/caddy/Caddyfile

# Reload caddy
pkill -HUP caddy

# View logs
cat /var/log/reverse-proxy/current
```

## Disk Management

```bash
# Check partition layout
lsblk
fdisk -l

# Expand state partition to full disk
qos-expand /dev/sda

# Check filesystem usage
df -h
du -sh /var/*
```

## Time Synchronization

```bash
# Check chrony status
ps aux | grep chronyd

# Check system time
date

# View chrony logs
cat /var/log/chrony/current
```

## Troubleshooting

```bash
# Check kernel messages
dmesg | tail -50

# Check all service logs
find /var/log -name "current" -exec cat {} \;

# Check cgroups
cat /sys/fs/cgroup/cgroup.controllers
mount | grep cgroup2

# Check security features
grep Seccomp /proc/self/status
cat /proc/sys/kernel/randomize_va_space

# Test network connectivity
ping -c 3 8.8.8.8
ping -c 3 google.com

# Check firewall rules
nft list ruleset
```

## File Locations

```
/etc/qos/capabilities/profiles/   - Capability profiles
/etc/qos/cluster/node.conf        - Cluster configuration
/etc/caddy/Caddyfile              - Reverse proxy config
/etc/chrony/chrony.conf           - NTP configuration
/var/log/<service>/current        - Service logs
/var/lib/webapp/                  - Webapp data directory
/var/lib/cluster/                 - Cluster data directory
/run/service/                     - s6 service directories
/sys/fs/cgroup/                   - Cgroups v2 hierarchy
```

## Common Issues

```bash
# Service not starting?
cat /var/log/<service>/current

# No network?
busybox udhcpc -i eth0 -T 5 -t 10

# Can't apply capability?
mkdir -p /sys/fs/cgroup/<service>
qos-capability apply <service> <profile>

# Reverse proxy not routing?
caddy validate --config /etc/caddy/Caddyfile
curl -v http://localhost:80

# Cluster not discovering nodes?
# Check multicast routing and firewall
ip route show | grep multicast
```

---

**End of Quick Reference Card**
