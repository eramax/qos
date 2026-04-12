#!/bin/sh
# qos-install - Install QOS to disk
# Usage: qos-install [--auto] <device>
#   --auto    Non-interactive mode (no prompts)
#   <device>  Target disk device (e.g., /dev/sda, /dev/vda)
#
# This script takes the running QOS system and installs it to a larger disk,
# creating proper partitions for boot, root, and var.

set -e

# Configuration
IMAGE_SIZE_MB=100
EFI_SIZE_MB=64
ROOT_SIZE_MB=32
ROOTFS_MOUNT="/ro-root"
STATE_MOUNT="/state"
INSTALL_LOG="/var/log/qos-install.log"

# Colors
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

AUTO_MODE=0
TARGET_DEV=""

log() {
    echo "[$(date -Iseconds)] $*" >> "$INSTALL_LOG" 2>/dev/null || true
    printf "${BLUE}[INSTALL]${NC} %s\n" "$*"
}

error() {
    printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
    log "ERROR: $*"
    exit 1
}

warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$*"
    log "WARN: $*"
}

usage() {
    cat <<EOF
Usage: qos-install [--auto] <device>

Install QOS to disk with proper partition layout.

Options:
  --auto    Non-interactive mode (no prompts)
  <device>  Target disk device (e.g., /dev/sda, /dev/vda)

Examples:
  qos-install /dev/sda
  qos-install --auto /dev/vda

Partition Layout:
  EFI:   ${EFI_SIZE_MB}MB  (bootloader + kernel + initramfs)
  Root:  ${ROOT_SIZE_MB}MB  (immutable root filesystem)
  Var:   Remaining space (writable state, logs, app data)

This script will:
  1. Detect target disk and size
  2. Create partition table (GPT)
  3. Format partitions
  4. Copy root filesystem
  5. Install bootloader
  6. Configure for first boot
EOF
}

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO_MODE=1 ;;
        --help|-h) usage; exit 0 ;;
        -*) error "Unknown option: $arg" ;;
        *) TARGET_DEV="$arg" ;;
    esac
done

[ -n "$TARGET_DEV" ] || error "Target device required. Use: qos-install <device>"
[ -b "$TARGET_DEV" ] || error "Not a block device: $TARGET_DEV"

log "══════════════════════════════════════════════════════════"
log "QOS Disk Installation"
log "══════════════════════════════════════════════════════════"
log "Target device: $TARGET_DEV"
log "Auto mode: $AUTO_MODE"

# Detect disk size
DISK_SIZE_BYTES="$(blockdev --getsize64 "$TARGET_DEV" 2>/dev/null || echo 0)"
DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))

if [ "$DISK_SIZE_MB" -eq 0 ]; then
    error "Could not detect disk size for $TARGET_DEV"
fi

log "Disk size: ${DISK_SIZE_MB}MB"

# Calculate var partition size
VAR_SIZE_MB=$((DISK_SIZE_MB - EFI_SIZE_MB - ROOT_SIZE_MB - 4)) # 4MB for alignment

if [ "$VAR_SIZE_MB" -lt 100 ]; then
    error "Disk too small. Need at least $((EFI_SIZE_MB + ROOT_SIZE_MB + 100))MB, have ${DISK_SIZE_MB}MB"
fi

log "Partition plan:"
log "  EFI: ${EFI_SIZE_MB}MB"
log "  Root: ${ROOT_SIZE_MB}MB"
log "  Var: ${VAR_SIZE_MB}MB (remaining space)"

# Confirm installation
if [ "$AUTO_MODE" -eq 0 ]; then
    printf "\n${YELLOW}WARNING: This will erase all data on %s${NC}\n" "$TARGET_DEV"
    printf "Continue? [y/N] "
    read -r CONFIRM
    case "$CONFIRM" in
        [yY][eE][sS]|[yY]) ;;
        *) log "Installation cancelled"; exit 0 ;;
    esac
fi

log "Starting installation..."

# Create partition table
log "Creating GPT partition table..."
sgdisk --zap-all "$TARGET_DEV" >/dev/null 2>&1 || error "Failed to zap disk"
sgdisk -o "$TARGET_DEV" >/dev/null 2>&1 || error "Failed to create partition table"

# Create partitions
log "Creating partitions..."
sgdisk -n 1:1M:+${EFI_SIZE_MB}M -t 1:ef00 -c 1:"QOS-EFI" "$TARGET_DEV" >/dev/null 2>&1 || error "Failed to create EFI partition"
sgdisk -n 2:0:+${ROOT_SIZE_MB}M -t 2:8300 -c 2:"QOS-Root" "$TARGET_DEV" >/dev/null 2>&1 || error "Failed to create root partition"
sgdisk -n 3:0:0 -t 3:8300 -c 3:"QOS-Var" "$TARGET_DEV" >/dev/null 2>&1 || error "Failed to create var partition"

log "Partition table created successfully"

# Format partitions
log "Formatting EFI partition (FAT32)..."
mkfs.vfat -F 32 -n "QOS-EFI" "${TARGET_DEV}1" >/dev/null 2>&1 || error "Failed to format EFI partition"

log "Formatting root partition (ext4)..."
mkfs.ext4 -F -L "QOS-Root" "${TARGET_DEV}2" >/dev/null 2>&1 || error "Failed to format root partition"

log "Formatting var partition (ext4)..."
mkfs.ext4 -F -L "QOS-Var" "${TARGET_DEV}3" >/dev/null 2>&1 || error "Failed to format var partition"

log "All partitions formatted"

# Mount partitions
MNT_ROOT="$(mktemp -d)"
MNT_EFI="$(mktemp -d)"
MNT_VAR="$(mktemp -d)"

log "Mounting partitions..."
mount "${TARGET_DEV}2" "$MNT_ROOT" || error "Failed to mount root partition"
mount "${TARGET_DEV}1" "$MNT_EFI" || error "Failed to mount EFI partition"
mount "${TARGET_DEV}3" "$MNT_VAR" || error "Failed to mount var partition"

# Copy root filesystem
log "Copying root filesystem..."
ROOTFS_SIZE="$(du -sm / 2>/dev/null | awk '{print $1}')"
log "Root filesystem size: ${ROOTFS_SIZE}MB"

# Use rsync if available, otherwise use cp
if command -v rsync >/dev/null 2>&1; then
    rsync -aAXv /* "$MNT_ROOT/" --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* --exclude=/var/* 2>&1 | tail -5
elif command -v tar >/dev/null 2>&1; then
    tar cf - \
        --exclude=/dev/* \
        --exclude=/proc/* \
        --exclude=/sys/* \
        --exclude=/tmp/* \
        --exclude=/run/* \
        --exclude=/mnt/* \
        --exclude=/var/* \
        -C / . | tar xf - -C "$MNT_ROOT"
else
    # Fallback to cp
    cp -a /etc /bin /sbin /usr /lib /lib64 /opt /srv /home /root "$MNT_ROOT/" 2>/dev/null || true
fi

log "Root filesystem copied"

# Setup var partition
log "Setting up var partition..."
mkdir -p "$MNT_VAR/lib/qos" "$MNT_VAR/log" "$MNT_VAR/cache"
mkdir -p "$MNT_VAR/overlay/upper" "$MNT_VAR/overlay/work"

# Copy persistent data
cp -a /var/lib/dropbear "$MNT_VAR/lib/" 2>/dev/null || true
cp -a /var/log/* "$MNT_VAR/log/" 2>/dev/null || true

log "Var partition setup complete"

# Setup EFI partition
log "Setting up EFI partition..."
mkdir -p "$MNT_EFI/EFI/BOOT" "$MNT_EFI/qos"

# Copy boot artifacts if they exist
if [ -f /boot/vmlinuz ]; then
    cp /boot/vmlinuz "$MNT_EFI/qos/"
    log "Kernel copied to EFI"
fi

if [ -f /boot/initramfs.img ]; then
    cp /boot/initramfs.img "$MNT_EFI/qos/"
    log "Initramfs copied to EFI"
fi

# Create EFI boot entry
cat > "$MNT_EFI/EFI/BOOT/startup.nsh" <<'EOF'
\EFI\BOOT\BOOTX64.EFI
EOF

# Create limine config if it exists
if [ -f /boot/limine.conf ]; then
    cp /boot/limine.conf "$MNT_EFI/EFI/BOOT/"
fi

log "EFI partition setup complete"

# Update fstab
log "Updating fstab..."
cat > "$MNT_ROOT/etc/fstab" <<EOF
# QOS filesystem table
LABEL=QOS-Root  /     ext4  ro,relatime  0 1
LABEL=QOS-EFI   /boot/efi  vfat  rw,relatime  0 2
LABEL=QOS-Var   /var  ext4  rw,relatime  0 2
tmpfs           /run  tmpfs rw,nosuid,nodev,mode=0755  0 0
tmpfs           /tmp  tmpfs rw,nosuid,nodev,mode=1777  0 0
EOF

log "fstab updated"

# Create installation marker
cat > "$MNT_VAR/lib/qos/installed.conf" <<EOF
# QOS installation metadata
INSTALL_DATE="$(date -Iseconds)"
TARGET_DEV="$TARGET_DEV"
DISK_SIZE_MB="$DISK_SIZE_MB"
EFI_SIZE_MB="$EFI_SIZE_MB"
ROOT_SIZE_MB="$ROOT_SIZE_MB"
INSTALLED_BY="qos-install"
EOF

log "Installation marker created"

# Cleanup mounts
log "Unmounting partitions..."
umount "$MNT_EFI" || warn "Failed to unmount EFI"
umount "$MNT_VAR" || warn "Failed to unmount var"
umount "$MNT_ROOT" || warn "Failed to unmount root"

rm -rf "$MNT_ROOT" "$MNT_EFI" "$MNT_VAR"

log "══════════════════════════════════════════════════════════"
log "✅ Installation Complete!"
log "══════════════════════════════════════════════════════════"
log ""
log "Disk layout:"
log "  ${TARGET_DEV}1  EFI (${EFI_SIZE_MB}MB)  - Bootloader"
log "  ${TARGET_DEV}2  Root (${ROOT_SIZE_MB}MB) - System"
log "  ${TARGET_DEV}3  Var (${VAR_SIZE_MB}MB)   - Data"
log ""
log "Next steps:"
log "  1. Shutdown: poweroff"
log "  2. Boot from installed disk"
log "  3. System will use new partition layout"
log ""
log "Installation log: $INSTALL_LOG"
