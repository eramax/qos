#!/bin/sh
# Init script for live ISO boot
# Uses tmpfs instead of disk partitions

set -eu
PATH=/bin

exec >/dev/console 2>&1
echo "[live-init] initramfs started"

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /run

echo "[live-init] Setting up live environment..."

# Create sysroot on tmpfs (256MB)
mkdir -p /sysroot
mount -t tmpfs -o size=256M,mode=0755 livefs /sysroot

# Copy rootfs from ISO (cdrom)
echo "[live-init] Mounting CD-ROM..."
mkdir -p /cdrom
mount -t iso9660 /dev/sr0 /cdrom 2>/dev/null || {
    echo "[live-init] CD-ROM not found, trying /dev/sr1..."
    mount -t iso9660 /dev/sr1 /cdrom 2>/dev/null || {
        echo "[live-init] No CD-ROM found, using empty rootfs"
        mkdir -p /cdrom
    }
}

echo "[live-init] Extracting root filesystem..."
if [ -f /cdrom/rootfs.squashfs ]; then
    # If we have squashfs, use it
    mount -t squashfs /cdrom/rootfs.squashfs /sysroot -o loop 2>/dev/null || true
elif [ -f /cdrom/rootfs.tar.gz ]; then
    # If we have tarball, extract it
    tar xzf /cdrom/rootfs.tar.gz -C /sysroot 2>/dev/null || true
else
    # Create minimal live rootfs
    echo "[live-init] Creating minimal live rootfs..."
    for d in bin sbin etc usr/lib usr/bin var/log var/tmp proc sys dev tmp run home root; do
        mkdir -p /sysroot/$d
    done
    
    # Copy essential binaries from initramfs
    cp -a /bin/busybox /sysroot/bin/
    cd /sysroot/bin
    for applet in $(/bin/busybox --list); do
        ln -sf busybox "$applet" 2>/dev/null || true
    done
    cd /
    
    # Try to copy from CD if available
    if [ -d /cdrom/rootfs ]; then
        cp -a /cdrom/rootfs/* /sysroot/ 2>/dev/null || true
    fi
fi

# Mount essential filesystems
echo "[live-init] Mounting filesystems..."
mount -t proc proc /sysroot/proc 2>/dev/null || true
mount -t sysfs sysfs /sysroot/sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /sysroot/dev 2>/dev/null || true
mount -t tmpfs tmpfs /sysroot/tmp -o nosuid,nodev,mode=1777 2>/dev/null || true
mount -t tmpfs tmpfs /sysroot/run -o nosuid,nodev,mode=0755 2>/dev/null || true

# Setup cgroups
mkdir -p /sysroot/sys/fs/cgroup
mount -t cgroup2 cgroup2 /sysroot/sys/fs/cgroup 2>/dev/null || true

# Set hostname
echo "qos-live" > /sysroot/etc/hostname 2>/dev/null || true
echo "qos-live" > /proc/sys/kernel/hostname 2>/dev/null || true

echo "[live-init] Switching to live rootfs..."
exec switch_root /sysroot /sbin/init
