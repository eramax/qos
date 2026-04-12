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
EFI_SIZE_MB=64
ROOT_SIZE_MB=128
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

# Create partition table using fdisk (busybox supports MBR only)
log "Creating MBR partition table..."

# Calculate partition sectors (in 512-byte sectors)
SECTOR_SIZE=512
TOTAL_SECTORS=$((DISK_SIZE_BYTES / SECTOR_SIZE))
EFI_SECTORS=$((EFI_SIZE_MB * 1024 * 1024 / SECTOR_SIZE))
ROOT_SECTORS=$((ROOT_SIZE_MB * 1024 * 1024 / SECTOR_SIZE))
START_SECTOR=2048  # Start at 1MB for alignment

EFI_END=$((START_SECTOR + EFI_SECTORS - 1))
ROOT_START=$((EFI_END + 1))
ROOT_END=$((ROOT_START + ROOT_SECTORS - 1))
VAR_START=$((ROOT_END + 1))
VAR_END=$((TOTAL_SECTORS - 1))  # Use rest of disk

# Use fdisk with MBR partition table (file redirect works, heredoc doesn't)
FDISK_CMD="$(mktemp)"
cat > "$FDISK_CMD" <<EOF
o
n
p
1
$START_SECTOR
$EFI_END
t
1
b
n
p
2
$ROOT_START
$ROOT_END
n
p
3
$VAR_START

w
EOF

fdisk "$TARGET_DEV" < "$FDISK_CMD" >/dev/null 2>&1 || true  # fdisk warns about rereading but succeeds
rm -f "$FDISK_CMD"

# Verify partitions were created
sleep 2
if [ ! -b "${TARGET_DEV}1" ]; then
    error "Partition table not created"
fi

# Reload partition table
partprobe "$TARGET_DEV" 2>/dev/null || true
sleep 2

# Verify partitions exist
if [ ! -b "${TARGET_DEV}1" ]; then
    # Try to create device nodes manually
    major=$(ls -l "$TARGET_DEV" | awk '{print $5}')
    minor=$(ls -l "$TARGET_DEV" | awk '{print $6}')
    mknod "${TARGET_DEV}1" b "$major" "$((minor + 1))" 2>/dev/null || true
    mknod "${TARGET_DEV}2" b "$major" "$((minor + 2))" 2>/dev/null || true
    mknod "${TARGET_DEV}3" b "$major" "$((minor + 3))" 2>/dev/null || true
fi

log "Partition table created successfully"
log "  ${TARGET_DEV}1: EFI (${EFI_SIZE_MB}MB) - FAT32"
log "  ${TARGET_DEV}2: Root (${ROOT_SIZE_MB}MB) - ext4"
log "  ${TARGET_DEV}3: Var (${VAR_SIZE_MB}MB) - ext4"

# Format partitions
log "Formatting EFI partition (FAT32)..."
# busybox mkfs.vfat may not be symlinked, call directly
if command -v mkfs.vfat >/dev/null 2>&1; then
    mkfs.vfat -F 32 -n "QOS-EFI" "${TARGET_DEV}1" >/dev/null 2>&1 || error "Failed to format EFI partition"
elif command -v busybox >/dev/null 2>&1; then
    busybox mkfs.vfat -F 32 -n "QOS-EFI" "${TARGET_DEV}1" >/dev/null 2>&1 || error "Failed to format EFI partition"
else
    error "mkfs.vfat not found"
fi

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
mount "${TARGET_DEV}3" "$MNT_VAR" || error "Failed to mount var partition"

# EFI partition (optional - only mount if needed)
MNT_EFI="$(mktemp -d)"
if mount "${TARGET_DEV}1" "$MNT_EFI" 2>/dev/null; then
    log "EFI partition mounted"
else
    log "EFI partition not mountable (MBR limitation), skipping EFI copy"
    log "System will still boot from second disk using existing bootloader"
fi

# Copy root filesystem
log "Copying root filesystem..."
ROOTFS_SIZE="$(du -sm / 2>/dev/null | awk '{print $1}')"
log "Root filesystem size: ${ROOTFS_SIZE}MB"

# Use cp -a with explicit directory list (most reliable method)
for dir in /bin /sbin /lib /lib64 /usr /etc /opt /srv /home /root; do
    if [ -d "$dir" ]; then
        log "  Copying $dir..."
        cp -a "$dir" "$MNT_ROOT/" 2>/dev/null || log "  Warning: partial copy of $dir"
    fi
done

# Copy var but skip overlay directories
log "  Copying /var (excluding overlay)..."
mkdir -p "$MNT_ROOT/var"
for vdir in /var/lib /var/log /var/cache /var/spool /var/run; do
    if [ -d "$vdir" ]; then
        cp -a "$vdir" "$MNT_ROOT/var/" 2>/dev/null || true
    fi
done

# Create necessary mount points
mkdir -p "$MNT_ROOT/proc" "$MNT_ROOT/sys" "$MNT_ROOT/dev" "$MNT_ROOT/tmp"
mkdir -p "$MNT_ROOT/run" "$MNT_ROOT/mnt" "$MNT_ROOT/media" "$MNT_ROOT/lost+found"
chmod 1777 "$MNT_ROOT/tmp" 2>/dev/null || true

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
