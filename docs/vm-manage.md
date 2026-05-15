# vm-manage — VirtualBox VM Management

Complete command-line management of QOS VirtualBox VMs with one-line creation, booting, and ISO management.

## Quick Start

```bash
# Create server VM
make vm-create PROFILE=server

# Boot it
make vm-boot PROFILE=server

# SSH in
make vm-ssh PROFILE=server

# Boot a different ISO via bootiso
make vm-bootiso PROFILE=server ISO=dist/qos-desktop.iso

# List all VMs
make vm-list
```

## Usage

### Via Make Targets

```bash
make vm-<command> PROFILE=<profile> [ISO=<iso>]
```

### Via Direct Script

```bash
bash builder/tools/vm-manage.sh <command> [profile] [options]
```

## Commands

### Create VM

**Create a new VM from a profile:**

```bash
make vm-create PROFILE=server
make vm-create PROFILE=desktop
```

Profiles:
- `server` — Headless, 1GB RAM, 2 CPUs, 4GB disk
- `desktop` — GUI, 8GB RAM, 4 CPUs, 8GB disk

**Auto-cleanup:** If VM exists, you'll be prompted to delete it first.

### Boot VM

**Start and boot a VM:**

```bash
make vm-boot PROFILE=server
```

**Result:**
- VM boots in headless mode
- You can SSH at `localhost:2222`
- Serial log at `virtualbox/qos-{profile}/serial.log`

### Stop VM

**Gracefully stop a running VM:**

```bash
make vm-stop PROFILE=server
```

### Delete VM

**Remove a VM and its disk:**

```bash
make vm-delete PROFILE=server
```

**Prompts for confirmation** (use `--force` to skip in scripts).

### SSH into VM

**Interactive shell:**

```bash
make vm-ssh PROFILE=server
```

**Execute a command:**

```bash
make vm-ssh PROFILE=server       # Will prompt for shell
sshpass -p emo2500 ssh -p 2222 emo@localhost "uname -a"
```

### Boot ISO via bootiso

**Copy ISO to VM and execute bootiso:**

```bash
make vm-bootiso PROFILE=server ISO=dist/qos-desktop.iso
```

**What happens:**
1. Copies ISO to VM (`/tmp/boot.iso`)
2. Executes `bootiso /tmp/boot.iso`
3. System boots into ISO (via kexec)
4. On reboot, returns to original disk

### List VMs

**Show all QOS VMs and their status:**

```bash
make vm-list
```

**Output:**
```
● qos-server    running
○ qos-desktop   stopped
```

### VM Info

**Show VM configuration:**

```bash
make vm-info PROFILE=server
```

**Shows:** RAM, CPUs, VRAM, disk, status, etc.

### Help

**Show command reference:**

```bash
make vm-help
```

## Workflows

### Workflow 1: Quick Server Test

```bash
# Build server ISO
make server

# Create, boot, and SSH in one go
make vm-create PROFILE=server
make vm-boot PROFILE=server
make vm-ssh PROFILE=server

# In VM shell:
# root@qos:~# bootiso /path/to/alpine.iso
```

### Workflow 2: Test Desktop on Different Profiles

```bash
# Build both profiles
make server desktop

# Create both VMs
make vm-create PROFILE=server
make vm-create PROFILE=desktop

# Boot server, test it
make vm-boot PROFILE=server
make vm-ssh PROFILE=server
# ... test ...

# Boot desktop in parallel
make vm-boot PROFILE=desktop

# List both running
make vm-list
```

### Workflow 3: Boot Different ISO on Same VM

```bash
# Start with server
make vm-create PROFILE=server
make vm-boot PROFILE=server

# Test server ISO
make vm-bootiso PROFILE=server ISO=dist/qos-server.iso

# After reboot, boot desktop ISO
make vm-bootiso PROFILE=server ISO=dist/qos-desktop.iso
```

### Workflow 4: qos-install Flow

```bash
# Create and boot live ISO
make vm-create PROFILE=server
make vm-boot PROFILE=server

# SSH and install to disk
make vm-ssh PROFILE=server "qos-install --auto /dev/vda"

# Shutdown, wait for reboot (back to original)
make vm-stop PROFILE=server
sleep 5

# Boot from installed disk (will use installed system)
make vm-boot PROFILE=server
```

## Environment Variables

Set defaults to avoid repeating parameters:

```bash
export PROFILE=server
make vm-create
make vm-boot
make vm-ssh
```

Or in a `.env` file:

```bash
# ~/.qos-vm.env
export PROFILE=server

source ~/.qos-vm.env
make vm-list
make vm-ssh
```

## Configuration

### VM Directory

VMs are created in `virtualbox/qos-{profile}/`:
```
virtualbox/
├── qos-server/
│   ├── qos-server.vbox
│   ├── qos-server.vdi      (4GB disk image)
│   └── Logs/
└── qos-desktop/
    ├── qos-desktop.vbox
    ├── qos-desktop.vdi     (8GB disk image)
    └── Logs/
```

### SSH Credentials

- **Host:** `localhost`
- **Port:** `2222` (NAT port forwarding)
- **User:** `emo`
- **Password:** `emo2500`

### Serial Console

Serial output is logged to:
```
virtualbox/qos-{profile}/serial.log
```

Monitor with:
```bash
tail -f virtualbox/qos-server/serial.log
```

## Troubleshooting

### "VM does not exist"

Create it first:
```bash
make vm-create PROFILE=server
```

### "Failed to start VM" or "No space"

Check disk space:
```bash
df -h virtualbox/
```

Delete VM and recreate:
```bash
make vm-delete PROFILE=server --force
make vm-create PROFILE=server
```

### SSH connection timeout

VM is still booting. Wait 20-30 seconds:
```bash
sleep 30
make vm-ssh PROFILE=server
```

Or check boot progress:
```bash
tail -f virtualbox/qos-server/serial.log
```

### ISO not found

Build the profile first:
```bash
make desktop
make vm-bootiso PROFILE=server ISO=dist/qos-desktop.iso
```

### Too many VMs / out of RAM

List and delete old VMs:
```bash
make vm-list
make vm-delete PROFILE=desktop
```

## Advanced Usage

### Script-based VM Testing

```bash
#!/bin/bash
for profile in server desktop; do
  make vm-create PROFILE=$profile
  make vm-boot PROFILE=$profile
  sleep 30
  make vm-ssh PROFILE=$profile "uname -a; uptime"
  make vm-stop PROFILE=$profile
done
```

### Monitor Multiple VMs

```bash
# Terminal 1: Boot and monitor server
make vm-boot PROFILE=server
tail -f virtualbox/qos-server/serial.log

# Terminal 2: Boot and monitor desktop
make vm-boot PROFILE=desktop
tail -f build/screens/qos-desktop-serial.log

# Terminal 3: SSH into either
make vm-ssh PROFILE=server    # or desktop
```

### Automated bootiso Testing

```bash
# Create and boot
make vm-create PROFILE=server
make vm-boot PROFILE=server
sleep 30

# Boot server ISO
make vm-bootiso PROFILE=server ISO=dist/qos-server.iso
sleep 30

# Boot desktop ISO (will reboot into it)
make vm-bootiso PROFILE=server ISO=dist/qos-desktop.iso
```

## See Also

- `make vm-help` — Quick reference
- `docs/bootiso-remote.md` — Boot ISO on remote hosts
- `docs/boot.md` — Technical details on kexec
- `virtualbox/create-vm.sh` — Original standalone script
