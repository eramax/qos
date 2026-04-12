#!/bin/sh
# qos-install - Install QOS to disk with GPT partitioning
# Usage: qos-install [--auto] <device>
#   --auto    Non-interactive mode (no prompts)
#   <device>  Target disk device (e.g., /dev/sda, /dev/vda)

set -e

# Ensure we can find system tools in /sbin and /usr/sbin
export PATH=/usr/sbin:/sbin:/usr/bin:/bin:$PATH

# Configuration
EFI_SIZE_MB=64
ROOT_SIZE_MB=128
INSTALL_LOG="/var/log/qos-install.log"

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

Install QOS to disk with GPT partition layout (UEFI compatible).

Options:
  --auto    Non-interactive mode (no prompts)
  <device>  Target disk device (e.g., /dev/sda, /dev/vda)

Partition Layout (GPT):
  EFI:   ${EFI_SIZE_MB}MB  (type EF00, FAT32)
  Root:  ${ROOT_SIZE_MB}MB  (type 8300, ext4)
  Var:   Remaining space (type 8300, ext4)
EOF
}

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

# Check required tools
for cmd in sgdisk mkfs.ext4; do
    command -v "$cmd" >/dev/null 2>&1 || error "Required tool not found: $cmd (install gdisk/e2fsprogs)"
done

# mkfs.vfat might be busybox applet without symlink
if ! command -v mkfs.vfat >/dev/null 2>&1; then
    if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -q mkfs.vfat; then
        MKFS_VFAT="busybox mkfs.vfat"
    else
        error "mkfs.vfat not found (install dosfstools or ensure busybox has it)"
    fi
else
    MKFS_VFAT="mkfs.vfat"
fi

log "══════════════════════════════════════════════════════════"
log "QOS Disk Installation (GPT/UEFI)"
log "══════════════════════════════════════════════════════════"
log "Target device: $TARGET_DEV"
log "Auto mode: $AUTO_MODE"

DISK_SIZE_BYTES="$(blockdev --getsize64 "$TARGET_DEV" 2>/dev/null || echo 0)"
DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))

if [ "$DISK_SIZE_MB" -eq 0 ]; then
    error "Could not detect disk size for $TARGET_DEV"
fi

VAR_SIZE_MB=$((DISK_SIZE_MB - EFI_SIZE_MB - ROOT_SIZE_MB - 4))

if [ "$VAR_SIZE_MB" -lt 100 ]; then
    error "Disk too small. Need at least $((EFI_SIZE_MB + ROOT_SIZE_MB + 100))MB, have ${DISK_SIZE_MB}MB"
fi

log "Disk size: ${DISK_SIZE_MB}MB"
log "Partition plan:"
log "  EFI:  ${EFI_SIZE_MB}MB (GPT type EF00)"
log "  Root: ${ROOT_SIZE_MB}MB (GPT type 8300)"
log "  Var:  ${VAR_SIZE_MB}MB (remaining space)"

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

# Wipe existing partition table
log "Wiping existing partition table..."
dd if=/dev/zero of="$TARGET_DEV" bs=1M count=10 >/dev/null 2>&1
sgdisk --zap-all "$TARGET_DEV" >/dev/null 2>&1 || true

# Create GPT partition table
log "Creating GPT partition table..."
sgdisk -o "$TARGET_DEV" >/dev/null 2>&1 || error "Failed to create GPT partition table"

# Create partitions using sgdisk
log "Creating partitions..."
sgdisk -n 1:1M:+${EFI_SIZE_MB}M -t 1:ef00 -c 1:"QOS-EFI" "$TARGET_DEV" >/dev/null 2>&1 || error "Failed to create EFI partition"
sgdisk -n 2:0:+${ROOT_SIZE_MB}M -t 2:8300 -c 2:"QOS-Root" "$TARGET_DEV" >/dev/null 2>&1 || error "Failed to create root partition"
sgdisk -n 3:0:0 -t 3:8300 -c 3:"QOS-Var" "$TARGET_DEV" >/dev/null 2>&1 || error "Failed to create var partition"

log "GPT partition table created successfully"

# Reload partition table
partprobe "$TARGET_DEV" 2>/dev/null || true
sleep 2

# Verify partitions exist
if [ ! -b "${TARGET_DEV}1" ]; then
    error "Partition table not created, device nodes missing"
fi

log "  ${TARGET_DEV}1: EFI (${EFI_SIZE_MB}MB) - FAT32 (type EF00)"
log "  ${TARGET_DEV}2: Root (${ROOT_SIZE_MB}MB) - ext4"
log "  ${TARGET_DEV}3: Var (${VAR_SIZE_MB}MB) - ext4"

# Format partitions
log "Formatting EFI partition (FAT32)..."
$MKFS_VFAT -F 32 -n "QOS-EFI" "${TARGET_DEV}1" >/dev/null 2>&1 || error "Failed to format EFI partition"

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

if mount "${TARGET_DEV}1" "$MNT_EFI" 2>/dev/null; then
    log "EFI partition mounted"
else
    warn "EFI partition not mountable, skipping EFI copy"
fi

# Copy root filesystem
log "Copying root filesystem..."
ROOTFS_SIZE="$(du -sm / 2>/dev/null | awk '{print $1}')"
log "Root filesystem size: ${ROOTFS_SIZE}MB"

for dir in /bin /sbin /lib /lib64 /usr /etc /opt /srv /home /root; do
    if [ -d "$dir" ]; then
        log "  Copying $dir..."
        cp -a "$dir" "$MNT_ROOT/" 2>/dev/null || log "  Warning: partial copy of $dir"
    fi
done

log "  Copying /var (excluding overlay)..."
mkdir -p "$MNT_ROOT/var"
for vdir in /var/lib /var/log /var/cache /var/spool /var/run; do
    if [ -d "$vdir" ]; then
        cp -a "$vdir" "$MNT_ROOT/var/" 2>/dev/null || true
    fi
done

mkdir -p "$MNT_ROOT/proc" "$MNT_ROOT/sys" "$MNT_ROOT/dev" "$MNT_ROOT/tmp"
mkdir -p "$MNT_ROOT/run" "$MNT_ROOT/mnt" "$MNT_ROOT/media" "$MNT_ROOT/lost+found"
chmod 1777 "$MNT_ROOT/tmp" 2>/dev/null || true

log "Root filesystem copied"

# Setup var partition
log "Setting up var partition..."
mkdir -p "$MNT_VAR/lib/qos" "$MNT_VAR/log" "$MNT_VAR/cache"
mkdir -p "$MNT_VAR/overlay/upper" "$MNT_VAR/overlay/work"

cp -a /var/lib/dropbear "$MNT_VAR/lib/" 2>/dev/null || true
cp -a /var/log/* "$MNT_VAR/log/" 2>/dev/null || true

log "Var partition setup complete"

# Setup EFI partition (using mtools to avoid mounting issues)
log "Setting up EFI partition..."

# Check for Limine source to copy bootloader
limine_src="$root/build/cache/limine/limine"
# Fallback for installed environment where we might not have cache
if [[ ! -d "$limine_src" ]]; then
    # Try to find BOOTX64.EFI on the current boot disk's EFI partition
    current_efi_dev=$(df /boot/efi 2>/dev/null | tail -1 | awk '{print $1}')
    if [ -z "$current_efi_dev" ]; then
        # Fallback: try to find it
        current_efi_dev="/dev/vda1"
    fi
    
    log "Extracting BOOTX64.EFI from current system..."
    mkdir -p /tmp/current-efi
    mount -o ro "$current_efi_dev" /tmp/current-efi 2>/dev/null || true
    if [ -f /tmp/current-efi/EFI/BOOT/BOOTX64.EFI ]; then
        cp /tmp/current-efi/EFI/BOOT/BOOTX64.EFI /tmp/BOOTX64.EFI
        umount /tmp/current-efi 2>/dev/null
        BOOTX64_SRC="/tmp/BOOTX64.EFI"
    else
        warn "Could not find BOOTX64.EFI on current system"
        BOOTX64_SRC=""
    fi
else
    BOOTX64_SRC="$limine_src/BOOTX64.EFI"
fi

# Create directories on EFI partition using mcopy/mmd
# -i specifies the device
mmd -i "${TARGET_DEV}1" ::/EFI 2>/dev/null || true
mmd -i "${TARGET_DEV}1" ::/EFI/BOOT 2>/dev/null || true

# Copy Limine Bootloader
if [ -n "$BOOTX64_SRC" ] && [ -f "$BOOTX64_SRC" ]; then
    log "  Copying BOOTX64.EFI..."
    mcopy -i "${TARGET_DEV}1" "$BOOTX64_SRC" ::/EFI/BOOT/BOOTX64.EFI 2>/dev/null || error "Failed to copy BOOTX64.EFI"
fi

# Copy Kernel
if [ -f /boot/vmlinuz ]; then
    log "  Copying vmlinuz..."
    mcopy -i "${TARGET_DEV}1" /boot/vmlinuz ::/vmlinuz 2>/dev/null || warn "Failed to copy vmlinuz"
    # Also copy to boot dir for safety
    mcopy -i "${TARGET_DEV}1" /boot/vmlinuz ::/boot/vmlinuz 2>/dev/null || true
fi

# Copy Initramfs
if [ -f /boot/initramfs.img ]; then
    log "  Copying initramfs.img..."
    mcopy -i "${TARGET_DEV}1" /boot/initramfs.img ::/initramfs.img 2>/dev/null || warn "Failed to copy initramfs.img"
    mcopy -i "${TARGET_DEV}1" /boot/initramfs.img ::/boot/initramfs.img 2>/dev/null || true
fi

# Copy Limine Config
if [ -f /boot/limine.conf ]; then
    log "  Copying limine.conf..."
    mcopy -i "${TARGET_DEV}1" /boot/limine.conf ::/limine.conf 2>/dev/null || warn "Failed to copy limine.conf"
    mcopy -i "${TARGET_DEV}1" /boot/limine.conf ::/EFI/BOOT/limine.conf 2>/dev/null || true
fi

log "EFI partition setup complete"

# Update fstab
log "Updating fstab..."
cat > "$MNT_ROOT/etc/fstab" <<EOF
# QOS filesystem table (GPT installation)
LABEL=QOS-Root  /           ext4  ro,relatime  0 1
LABEL=QOS-EFI   /boot/efi   vfat  rw,relatime  0 2
LABEL=QOS-Var   /var        ext4  rw,relatime  0 2
tmpfs           /run        tmpfs rw,nosuid,nodev,mode=0755  0 0
tmpfs           /tmp        tmpfs rw,nosuid,nodev,mode=1777  0 0
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
PARTITION_TYPE=GPT
INSTALLED_BY="qos-install"
EOF

log "Installation marker created"

# Cleanup mounts
log "Unmounting partitions..."
umount "$MNT_EFI" 2>/dev/null || warn "Failed to unmount EFI"
umount "$MNT_VAR" || warn "Failed to unmount var"
umount "$MNT_ROOT" || warn "Failed to unmount root"

rm -rf "$MNT_ROOT" "$MNT_EFI" "$MNT_VAR"

# Verify installation
log "Verifying installation..."
if sgdisk -p "$TARGET_DEV" >/dev/null 2>&1; then
    log "GPT partition table verified"
    sgdisk -p "$TARGET_DEV" 2>/dev/null | grep -E "Number|EFI|Root|Var" | while read -r line; do
        log "  $line"
    done
else
    warn "Could not verify GPT partition table"
fi

log "══════════════════════════════════════════════════════════"
log "✅ Installation Complete!"
log "══════════════════════════════════════════════════════════"
log ""
log "Disk layout (GPT):"
log "  ${TARGET_DEV}1  EFI (${EFI_SIZE_MB}MB)  - Bootloader (type EF00)"
log "  ${TARGET_DEV}2  Root (${ROOT_SIZE_MB}MB) - System (type 8300)"
log "  ${TARGET_DEV}3  Var (${VAR_SIZE_MB}MB)   - Data (type 8300)"
log ""
log "Next steps:"
log "  1. Shutdown: poweroff"
log "  2. Boot from installed disk"
log "  3. System will use new GPT partition layout"
log ""
log "Installation log: $INSTALL_LOG"
