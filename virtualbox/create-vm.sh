#!/bin/bash
# Create/recreate the qos VirtualBox VM.
# Run from the project root directory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VM_NAME="${VM_NAME:-qos}"
VM_DIR="$SCRIPT_DIR/$VM_NAME"
ISO_PATH="$PROJECT_ROOT/dist/qos-desktop.iso"
SERIAL_LOG="$PROJECT_ROOT/build/screens/qos-serial.log"

# Ensure serial log directory exists
mkdir -p "$(dirname "$SERIAL_LOG")"

# Stop and remove existing VM if present
if VBoxManage showvminfo "$VM_NAME" &>/dev/null; then
  echo "Removing existing VM '$VM_NAME'..."
  VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
  sleep 2
  VBoxManage unregistervm "$VM_NAME" --delete 2>/dev/null || true
  rm -rf "$VM_DIR"
fi

mkdir -p "$VM_DIR"

# Create empty 2GB disk
if [ ! -f "$VM_DIR/qos.vdi" ]; then
  VBoxManage createmedium disk --filename "$VM_DIR/qos.vdi" --size 2048 --format VDI
fi

echo "Creating VM '$VM_NAME'..."

VBoxManage createvm \
  --name "$VM_NAME" \
  --ostype "Linux26_64" \
  --register \
  --basefolder "$SCRIPT_DIR"

# --- General ---
VBoxManage modifyvm "$VM_NAME" \
  --chipset piix3 \
  --firmware efi \
  --memory 8192 \
  --vram 128 \
  --cpus 4 \
  --pae on \
  --apic on \
  --ioapic on \
  --acpi on \
  --rtcuseutc on \
  --paravirtprovider kvm \
  --hwvirtex on \
  --nestedpaging on

# --- Boot ---
VBoxManage modifyvm "$VM_NAME" \
  --boot1 dvd \
  --boot2 disk

# --- GPU ---
VBoxManage modifyvm "$VM_NAME" \
  --graphicscontroller vmsvga \
  --accelerate3d on

# --- Mouse / Keyboard ---
VBoxManage modifyvm "$VM_NAME" \
  --mouse usbtablet \
  --keyboard ps2kbd \
  --clipboard bidirectional \
  --draganddrop bidirectional

# --- Audio ---
VBoxManage modifyvm "$VM_NAME" \
  --audio default \
  --audioout on \
  --audioin on

# --- USB ---
VBoxManage modifyvm "$VM_NAME" \
  --usb on \
  --usbehci on

# --- Network (NAT + SSH port forward on 2222) ---
VBoxManage modifyvm "$VM_NAME" \
  --nic1 nat \
  --nictype1 virtio \
  --cableconnected1 on

VBoxManage modifyvm "$VM_NAME" \
  --natpf1 "ssh,tcp,,2222,,22"

# --- Serial (redirect to log file) ---
VBoxManage modifyvm "$VM_NAME" \
  --uart1 0x3F8 4 \
  --uartmode1 file "$SERIAL_LOG"

# --- Storage ---
VBoxManage storagectl "$VM_NAME" \
  --name IDE --add ide --controller PIIX4 --bootable on

VBoxManage storagectl "$VM_NAME" \
  --name SATA --add sata --controller IntelAhci --bootable on

VBoxManage storageattach "$VM_NAME" \
  --storagectl IDE --port 0 --device 0 \
  --type dvddrive --medium "$ISO_PATH"

VBoxManage storageattach "$VM_NAME" \
  --storagectl SATA --port 0 --device 0 \
  --type hdd --medium "$VM_DIR/qos.vdi"

echo ""
echo "VM '$VM_NAME' created successfully."
echo ""
echo "Start:  VBoxManage startvm $VM_NAME --type gui"
echo "SSH:    sshpass -p 'root' ssh -p 2222 root@localhost"
echo "Stop:   VBoxManage controlvm $VM_NAME poweroff"
