#!/bin/sh
# qos-expand - Expand state partition to use remaining disk space
# Usage: qos-expand <device>
# Example: qos-expand /dev/sda

set -e

if [ -z "$1" ]; then
    echo "Usage: qos-expand <device>"
    echo "Example: qos-expand /dev/sda"
    echo ""
    echo "This tool expands the state partition to use remaining disk space"
    echo "after flashing a 64MB image to a larger disk."
    exit 1
fi

DEVICE="$1"

# Find the state partition
STATE_PART=""
for part in "${DEVICE}"*; do
    if blkid "$part" 2>/dev/null | grep -q "LABEL=qos-state"; then
        STATE_PART="$part"
        break
    fi
done

if [ -z "$STATE_PART" ]; then
    echo "Error: State partition not found on $DEVICE"
    echo "Available partitions:"
    for part in "${DEVICE}"*; do
        echo "  $part: $(blkid "$part" 2>/dev/null || echo 'unknown')"
    done
    exit 1
fi

echo "Found state partition: $STATE_PART"

# Check if we need to resize
CURRENT_SIZE="$(blockdev --getsize64 "$STATE_PART" 2>/dev/null || echo 0)"
DISK_SIZE="$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo 0)"

if [ "$CURRENT_SIZE" -gt 0 ] && [ "$DISK_SIZE" -gt 0 ]; then
    echo "Current state partition size: $(( CURRENT_SIZE / 1024 / 1024 )) MB"
    echo "Disk size: $(( DISK_SIZE / 1024 / 1024 )) MB"
    
    # Resize partition to use remaining space
    echo "Resizing state partition..."
    resize2fs "$STATE_PART"
    
    NEW_SIZE="$(blockdev --getsize64 "$STATE_PART" 2>/dev/null || echo 0)"
    echo "New state partition size: $(( NEW_SIZE / 1024 / 1024 )) MB"
    echo "Expansion complete!"
else
    echo "Error: Unable to determine partition sizes"
    exit 1
fi
