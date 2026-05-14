#!/usr/bin/env bash
# create-vm.sh — Create QOS Desktop VirtualBox VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VM_NAME="qos"
VM_DIR="$SCRIPT_DIR/qos"

# ── Profile configuration ───────────────────────────────────────────────────
PROFILE="${1:-desktop}"
if [[ "$PROFILE" == "server" ]]; then
  RAM_MB=2048
  CPUS=2
  ISO_PATH="$PROJECT_ROOT/dist/qos-server.iso"
else
  RAM_MB=8192
  CPUS=4
  ISO_PATH="$PROJECT_ROOT/dist/qos-desktop.iso"
fi

VRAM_MB=128
DISK_SIZE_MB=8192
SERIAL_LOG="$PROJECT_ROOT/build/screens/qos-serial.log"
SSH_HOST_PORT=2222
SSH_GUEST_PORT=22

# ── Cleanup existing VM ──────────────────────────────────────────────────────
if VBoxManage showvminfo "$VM_NAME" &>/dev/null; then
  echo "Removing existing VM '$VM_NAME'..."
  VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
  sleep 2
  VBoxManage unregistervm "$VM_NAME" --delete 2>/dev/null || true
fi
rm -rf "$VM_DIR"
mkdir -p "$VM_DIR"

# ── 1. Create and register the VM ─────────────────────────────────────────────
VBoxManage createvm \
  --name        "$VM_NAME" \
  --ostype      Linux_64 \
  --register \
  --basefolder  "$SCRIPT_DIR"

# ── 2. Firmware (EFI), Chipset (PIIX3), base hardware ─────────────────────────
VBoxManage modifyvm "$VM_NAME" \
  --firmware        efi \
  --chipset         piix3 \
  --memory          "$RAM_MB" \
  --cpus            "$CPUS" \
  --vram            "$VRAM_MB" \
  --graphicscontroller vmsvga \
  --accelerate3d    on

# ── 3. Input devices ──────────────────────────────────────────────────────────
VBoxManage modifyvm "$VM_NAME" \
  --mouse    usbtablet \
  --keyboard ps2

# ── 4. Audio (Intel AC'97, output + input) ────────────────────────────────────
VBoxManage modifyvm "$VM_NAME" \
  --audio-driver    default \
  --audio-controller ac97 \
  --audio-codec     ad1980 \
  --audio-out       on \
  --audio-in        on

# ── 5. Clipboard and drag-and-drop ────────────────────────────────────────────
VBoxManage modifyvm "$VM_NAME" \
  --clipboard-mode  bidirectional \
  --drag-and-drop   bidirectional

# ── 6. USB (EHCI / USB 2.0) ───────────────────────────────────────────────────
VBoxManage modifyvm "$VM_NAME" \
  --usb     on \
  --usbehci on

# ── 7. Network: NAT, virtio NIC, port-forward SSH ─────────────────────────────
VBoxManage modifyvm "$VM_NAME" \
  --nic1            nat \
  --nictype1        virtio \
  --cableconnected1 on

VBoxManage modifyvm "$VM_NAME" \
  --natpf1 "ssh,tcp,,${SSH_HOST_PORT},,${SSH_GUEST_PORT}"

# ── 8. Serial port: UART1 at 0x3F8 / IRQ 4 → file ────────────────────────────
mkdir -p "$(dirname "$SERIAL_LOG")"
VBoxManage modifyvm "$VM_NAME" \
  --uart1    0x3F8 4 \
  --uartmode1 file "$SERIAL_LOG"

# ── 9. Boot order: DVD first, then Disk ───────────────────────────────────────
VBoxManage modifyvm "$VM_NAME" \
  --boot1 dvd \
  --boot2 disk \
  --boot3 none \
  --boot4 none

# ── 10. CPU feature flags ─────────────────────────────────────────────────────
VBoxManage modifyvm "$VM_NAME" \
  --pae            on \
  --apic           on \
  --ioapic         on \
  --acpi           on \
  --rtcuseutc      on \
  --hwvirtex       on \
  --nestedpaging   on \
  --paravirt-provider kvm

# ── 11. Storage: SATA (DVD and VDI disk) ──────────────────────────────────────
VBoxManage storagectl "$VM_NAME" \
  --name       "SATA Controller" \
  --add        sata \
  --controller IntelAhci \
  --portcount  2

VBoxManage storageattach "$VM_NAME" \
  --storagectl "SATA Controller" \
  --port       0 \
  --device     0 \
  --type       dvddrive \
  --medium     "$ISO_PATH"

VDI_PATH="$VM_DIR/qos.vdi"
if [ ! -f "$VDI_PATH" ]; then
  VBoxManage createmedium disk \
    --filename "$VDI_PATH" \
    --size     "$DISK_SIZE_MB" \
    --format   VDI
fi

VBoxManage storageattach "$VM_NAME" \
  --storagectl "SATA Controller" \
  --port       1 \
  --device     0 \
  --type       hdd \
  --medium     "$VDI_PATH"

# ── 13. GUI preferences ───────────────────────────────────────────────────────
VBoxManage setextradata "$VM_NAME" "GUI/AutoresizeGuest" 1

echo ""
echo "VM '$VM_NAME' created successfully (profile: $PROFILE)."
echo "Start with:  VBoxManage startvm '$VM_NAME' --type gui"
echo "SSH (emo):   sshpass -p 'emo2500' ssh -p $SSH_HOST_PORT emo@localhost"
echo "SSH (root):  ssh -p $SSH_HOST_PORT -o StrictHostKeyChecking=no root@localhost"
echo "Note: Root password is disabled. Use your SSH key for root access."
