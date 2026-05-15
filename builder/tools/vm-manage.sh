#!/usr/bin/env bash
# vm-manage.sh — QOS VirtualBox VM management utility
# Create, boot, and manage QOS VMs with ease
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VBOX_DIR="${VBOX_DIR:-$PROJECT_ROOT/virtualbox}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults for profiles
declare -A PROFILE_CONFIG=(
    [server]="server|1024|2|16|4096"
    [desktop]="desktop|8192|4|128|8192"
)

log()   { printf "${BLUE}[VM]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
info()  { printf "${CYAN}ℹ${NC}  %s\n" "$*"; }

usage() {
    cat <<EOF
${BLUE}vm-manage${NC} — QOS VirtualBox VM Management

${BLUE}Usage:${NC}
  vm-manage.sh <command> [options]

${BLUE}Commands:${NC}
  create <profile>          Create a new VM from profile (server|desktop)
  boot <profile>            Start and boot a VM
  stop <profile>            Stop a running VM
  delete <profile>          Delete a VM and its disk
  ssh <profile> [cmd]       SSH into VM, optionally run command
  bootiso <profile> <iso>   SSH to VM and run bootiso with ISO file
  list                      List all QOS VMs
  info <profile>            Show VM configuration info
  help                      Show this help message

${BLUE}Profile Configurations:${NC}
  server                    Headless server (1GB RAM, 2 CPUs, 4GB disk)
  desktop                   Desktop with GUI (8GB RAM, 4 CPUs, 8GB disk)

${BLUE}Examples:${NC}
  # Create and boot server
  vm-manage.sh create server
  vm-manage.sh boot server

  # SSH and run command
  vm-manage.sh ssh server "sudo bootiso /tmp/alpine.iso"

  # Boot ISO via bootiso (copy and execute)
  vm-manage.sh bootiso server dist/qos-desktop.iso

  # List all VMs
  vm-manage.sh list

EOF
}

# Parse profile config: NAME|RAM|CPUS|VRAM|DISK
parse_profile() {
    local profile="$1"
    if [[ -z "${PROFILE_CONFIG[$profile]:-}" ]]; then
        error "Unknown profile: $profile"
    fi

    IFS='|' read -r name ram cpus vram disk <<< "${PROFILE_CONFIG[$profile]}"
    echo "$name:$ram:$cpus:$vram:$disk"
}

# Get VM directory
get_vm_dir() {
    local profile="$1"
    echo "$VBOX_DIR/qos-$profile"
}

# Get ISO path for profile
get_iso_path() {
    local profile="$1"
    echo "$PROJECT_ROOT/dist/qos-$profile.iso"
}

# Get serial log path
get_serial_log() {
    local profile="$1"
    echo "$PROJECT_ROOT/build/screens/qos-${profile}-serial.log"
}

# Check if VM exists
vm_exists() {
    local profile="$1"
    VBoxManage showvminfo "qos-$profile" &>/dev/null
}

# Check if VM is running
vm_running() {
    local profile="$1"
    VBoxManage list runningvms | grep -q "qos-$profile"
}

# Create VM from profile
cmd_create() {
    local profile="${1:-}"
    [[ -n "$profile" ]] || error "Profile required: server | desktop"

    local config=$(parse_profile "$profile")
    IFS=':' read -r name ram cpus vram disk <<< "$config"

    local vm_name="qos-$profile"
    local vm_dir=$(get_vm_dir "$profile")
    local iso_path=$(get_iso_path "$profile")
    local serial_log=$(get_serial_log "$profile")

    # Check ISO exists
    [[ -f "$iso_path" ]] || error "ISO not found: $iso_path (run: make $profile)"

    # Clean up existing VM
    if vm_exists "$profile"; then
        warn "VM '$vm_name' already exists"
        read -p "Delete and recreate? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cmd_delete "$profile" --force
        else
            error "VM already exists"
        fi
    fi

    log "Creating VM: $vm_name"
    log "  Profile:   $profile"
    log "  RAM:       ${ram}MB"
    log "  CPUs:      $cpus"
    log "  VRAM:      ${vram}MB"
    log "  Disk:      ${disk}MB"
    log "  ISO:       $iso_path"

    # Create directories
    rm -rf "$vm_dir"
    mkdir -p "$vm_dir"
    mkdir -p "$(dirname "$serial_log")"

    # Create VM
    VBoxManage createvm \
        --name        "$vm_name" \
        --ostype      Linux_64 \
        --register \
        --basefolder  "$VBOX_DIR"

    # Configure VM
    VBoxManage modifyvm "$vm_name" \
        --firmware        efi \
        --chipset         piix3 \
        --memory          "$ram" \
        --cpus            "$cpus" \
        --vram            "$vram" \
        --graphicscontroller vmsvga \
        --accelerate3d    on \
        --mouse           usbtablet \
        --keyboard        ps2 \
        --audio-driver    default \
        --audio-controller ac97 \
        --audio-codec     ad1980 \
        --audio-out       on \
        --audio-in        on \
        --clipboard-mode  bidirectional \
        --drag-and-drop   bidirectional \
        --usb             on \
        --usbehci         on \
        --nic1            bridged \
        --bridgeadapter1  wlp13s0 \
        --nictype1        virtio \
        --cableconnected1 on \
        --boot1           dvd \
        --boot2           disk \
        --boot3           none \
        --boot4           none \
        --pae             on \
        --apic            on \
        --ioapic          on \
        --acpi            on \
        --rtcuseutc       on \
        --hwvirtex        on \
        --nestedpaging    on \
        --paravirt-provider kvm

    # Serial port
    VBoxManage modifyvm "$vm_name" \
        --uart1        0x3F8 4 \
        --uartmode1    file "$serial_log"

    # GUI preferences
    VBoxManage setextradata "$vm_name" "GUI/AutoresizeGuest" 1

    # Storage controllers
    VBoxManage storagectl "$vm_name" \
        --name       "IDE Controller" \
        --add        ide \
        --controller PIIX4

    VBoxManage storagectl "$vm_name" \
        --name       "SATA Controller" \
        --add        sata \
        --controller IntelAhci \
        --portcount  1

    # Attach ISO
    VBoxManage storageattach "$vm_name" \
        --storagectl "IDE Controller" \
        --port       0 \
        --device     0 \
        --type       dvddrive \
        --medium     "$iso_path"

    # Create and attach disk
    local vdi_path="$vm_dir/qos-$profile.vdi"
    VBoxManage createmedium disk \
        --filename "$vdi_path" \
        --size     "$disk" \
        --format   VDI

    VBoxManage storageattach "$vm_name" \
        --storagectl "SATA Controller" \
        --port       0 \
        --device     0 \
        --type       hdd \
        --medium     "$vdi_path"

    ok "VM created: $vm_name"
    info "Start with:  make vm-boot PROFILE=$profile"
    info "SSH:         sshpass -p emo2500 ssh -p 2222 emo@localhost"
}

# Boot VM
cmd_boot() {
    local profile="${1:-}"
    [[ -n "$profile" ]] || error "Profile required: server | desktop"

    local vm_name="qos-$profile"

    vm_exists "$profile" || error "VM does not exist: $vm_name (create with: make vm-create PROFILE=$profile)"

    if vm_running "$profile"; then
        info "VM is already running: $vm_name"
        return 0
    fi

    log "Starting VM: $vm_name"
    VBoxManage startvm "$vm_name" --type headless || error "Failed to start VM"

    ok "VM started: $vm_name"
    log ""
    log "Finding VM IP address (bridged on wlp13s0)..."

    local serial_log=$(get_serial_log "$profile")

    # Wait for VM to get an IP and extract it from serial log
    local vm_ip=""
    local max_wait=60
    local elapsed=0
    while [[ -z "$vm_ip" && $elapsed -lt $max_wait ]]; do
        # Look for IP address in kernel messages on serial log
        vm_ip=$(grep -o 'inet [0-9.]*' "$serial_log" 2>/dev/null | tail -1 | awk '{print $2}' || true)
        if [[ -z "$vm_ip" ]]; then
            # Alternative: look for DHCP assignment
            vm_ip=$(grep -oP 'inet \K[0-9.]+' "$serial_log" 2>/dev/null | tail -1 || true)
        fi
        if [[ -z "$vm_ip" ]]; then
            sleep 2
            ((elapsed+=2))
        fi
    done

    if [[ -n "$vm_ip" ]]; then
        ok "VM IP: $vm_ip"
        info "SSH: sshpass -p emo2500 ssh -o StrictHostKeyChecking=no emo@$vm_ip"
    else
        log "Could not auto-detect IP. Check serial log:"
        info "tail -f $serial_log"
        log "Once booted, find the IP with: ip addr show"
        info "Then SSH with: sshpass -p emo2500 ssh -o StrictHostKeyChecking=no emo@<ip>"
    fi
}

# Stop VM
cmd_stop() {
    local profile="${1:-}"
    [[ -n "$profile" ]] || error "Profile required: server | desktop"

    local vm_name="qos-$profile"

    vm_exists "$profile" || error "VM does not exist: $vm_name"

    if ! vm_running "$profile"; then
        info "VM is not running: $vm_name"
        return 0
    fi

    log "Stopping VM: $vm_name"
    VBoxManage controlvm "$vm_name" poweroff || true

    sleep 2
    ok "VM stopped: $vm_name"
}

# Delete VM
cmd_delete() {
    local profile="${1:-}"
    local force="${2:-}"

    [[ -n "$profile" ]] || error "Profile required: server | desktop"

    local vm_name="qos-$profile"
    local vm_dir=$(get_vm_dir "$profile")

    vm_exists "$profile" || { info "VM does not exist: $vm_name"; return 0; }

    if [[ "$force" != "--force" ]]; then
        read -p "Delete VM '$vm_name' and all data? [y/N] " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || { warn "Cancelled"; return 0; }
    fi

    log "Deleting VM: $vm_name"

    # Stop if running
    vm_running "$profile" && VBoxManage controlvm "$vm_name" poweroff 2>/dev/null || true
    sleep 1

    # Unregister and delete
    VBoxManage unregistervm "$vm_name" --delete 2>/dev/null || true
    rm -rf "$vm_dir"

    ok "VM deleted: $vm_name"
}

# SSH into VM
cmd_ssh() {
    local profile="${1:-}"
    shift || true
    local cmd="${@:-}"

    [[ -n "$profile" ]] || error "Profile required: server | desktop"

    local vm_name="qos-$profile"
    local serial_log=$(get_serial_log "$profile")

    vm_exists "$profile" || error "VM does not exist: $vm_name"
    vm_running "$profile" || { log "Starting VM..."; cmd_boot "$profile"; sleep 30; }

    # Try to find VM's IP from serial log (bridged mode)
    local vm_ip=""
    local max_attempts=10
    for ((i=0; i<max_attempts; i++)); do
        vm_ip=$(grep -oP 'inet \K[0-9.]+' "$serial_log" 2>/dev/null | grep -v '^127\.' | tail -1 || true)
        if [[ -n "$vm_ip" ]]; then
            break
        fi
        if [[ $i -lt $((max_attempts-1)) ]]; then
            sleep 3
        fi
    done

    if [[ -z "$vm_ip" ]]; then
        error "Could not find VM's IP. Check serial log: tail -f $serial_log"
    fi

    log "Connecting to VM: $vm_name at $vm_ip"

    if [[ -z "$cmd" ]]; then
        # Interactive shell
        sshpass -p emo2500 ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            emo@"$vm_ip"
    else
        # Execute command
        sshpass -p emo2500 ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            emo@"$vm_ip" \
            "$cmd"
    fi
}

# Boot ISO via bootiso
cmd_bootiso() {
    local profile="${1:-}"
    local iso_file="${2:-}"

    [[ -n "$profile" ]] || error "Profile required: server | desktop"
    [[ -n "$iso_file" ]] || error "ISO file required"
    [[ -f "$iso_file" ]] || error "ISO not found: $iso_file"

    local vm_name="qos-$profile"
    local vm_dir=$(get_vm_dir "$profile")
    local serial_log=$(get_serial_log "$profile")
    local remote_iso="/tmp/boot.iso"
    local iso_size=$(du -h "$iso_file" | cut -f1)

    vm_exists "$profile" || error "VM does not exist: $vm_name"
    vm_running "$profile" || { log "Starting VM..."; cmd_boot "$profile"; sleep 30; }

    # Try to find VM's IP from serial log (bridged mode)
    local vm_ip=""
    local max_attempts=10
    for ((i=0; i<max_attempts; i++)); do
        vm_ip=$(grep -oP 'inet \K[0-9.]+' "$serial_log" 2>/dev/null | grep -v '^127\.' | tail -1 || true)
        if [[ -n "$vm_ip" ]]; then
            break
        fi
        if [[ $i -lt $((max_attempts-1)) ]]; then
            sleep 3
        fi
    done

    if [[ -z "$vm_ip" ]]; then
        error "Could not find VM's IP. Check serial log: tail -f $serial_log"
    fi

    log "Copying ISO to VM: $vm_name at $vm_ip"
    log "  Local:  $iso_file ($iso_size)"
    log "  Remote: $remote_iso"

    sshpass -p emo2500 scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$iso_file" \
        "emo@${vm_ip}:$remote_iso" || error "Failed to copy ISO"

    ok "ISO copied"

    log "Executing bootiso on VM..."
    log "  Command: bootiso $remote_iso"
    log ""

    sshpass -p emo2500 ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        emo@"$vm_ip" \
        "sudo bootiso '$remote_iso'" || true

    log ""
    ok "sudo bootiso executed"
    log "System is handing off to ISO kernel..."
}

# List VMs
cmd_list() {
    log "QOS VirtualBox VMs:"
    echo ""

    VBoxManage list vms | grep "qos-" || { info "No QOS VMs found"; return 0; }

    echo ""
    log "Status:"
    VBoxManage list runningvms | grep "qos-" && echo "" || true

    for vm in $(VBoxManage list vms | grep "qos-" | cut -d'"' -f2); do
        if VBoxManage list runningvms | grep -q "$vm"; then
            printf "  ${GREEN}●${NC} %-20s running\n" "$vm"
        else
            printf "  ${YELLOW}○${NC} %-20s stopped\n" "$vm"
        fi
    done
}

# VM info
cmd_info() {
    local profile="${1:-}"
    [[ -n "$profile" ]] || error "Profile required: server | desktop"

    local vm_name="qos-$profile"

    vm_exists "$profile" || error "VM does not exist: $vm_name"

    log "VM Info: $vm_name"
    echo ""

    VBoxManage showvminfo "$vm_name" --machinereadable | grep -E "^(name|memory|cpus|vram|State)=" | while IFS='=' read -r key value; do
        printf "  %-15s %s\n" "$key:" "$value"
    done

    echo ""
    if vm_running "$profile"; then
        printf "  %-15s ${GREEN}running${NC}\n" "Status:"
    else
        printf "  %-15s ${YELLOW}stopped${NC}\n" "Status:"
    fi
}

# Main command dispatcher
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        create)    cmd_create "$@" ;;
        boot)      cmd_boot "$@" ;;
        stop)      cmd_stop "$@" ;;
        delete)    cmd_delete "$@" ;;
        ssh)       cmd_ssh "$@" ;;
        bootiso)   cmd_bootiso "$@" ;;
        list)      cmd_list "$@" ;;
        info)      cmd_info "$@" ;;
        help|--help|-h) usage ;;
        *)         error "Unknown command: $cmd (use 'help' for usage)" ;;
    esac
}

main "$@"
