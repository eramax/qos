# Testing Guide — bootiso & VM Management

Complete command reference for testing the bootiso feature and VM management system.

## Quick Test Sequence (Copy & Paste)

```bash
# 1. Build server and desktop ISOs
make server
make desktop

# 2. Create server VM
make vm-create PROFILE=server

# 3. Boot it
make vm-boot PROFILE=server

# 4. Wait 30 seconds for boot
sleep 30

# 5. List VMs to verify it's running
make vm-list

# 6. Check VM info
make vm-info PROFILE=server

# 7. SSH and verify bootiso is installed
sshpass -p emo2500 ssh -o StrictHostKeyChecking=no -p 2222 emo@localhost "which bootiso && bootiso --help"

# 8. Test bootiso command on remote system
make vm-ssh PROFILE=server  # or run: sshpass -p emo2500 ssh -o StrictHostKeyChecking=no -p 2222 emo@localhost

# 9. Boot desktop ISO via bootiso
make vm-bootiso PROFILE=server ISO=dist/qos-server.iso

# 10. Stop and clean up
make vm-stop PROFILE=server
make vm-delete PROFILE=server
```

---

## Test Scenarios

### Scenario 1: Basic VM Operations

```bash
# Build ISOs first
make server desktop

# Create server VM
make vm-create PROFILE=server

# Create desktop VM
make vm-create PROFILE=desktop

# List all VMs
make vm-list

# Check server VM config
make vm-info PROFILE=server

# Boot server
make vm-boot PROFILE=server

# List again (should show running)
make vm-list

# Stop VM
make vm-stop PROFILE=server

# Delete VM
make vm-delete PROFILE=server
```

### Scenario 2: SSH into VM

```bash
# Build and create VM
make server
make vm-create PROFILE=server
make vm-boot PROFILE=server
sleep 30

# SSH into VM shell (interactive)
make vm-ssh PROFILE=server

# Inside VM, test bootiso help
bootiso --help

# Exit
exit
```

### Scenario 3: Boot ISO via bootiso

```bash
# Build both ISOs
make server desktop

# Create and boot server VM
make vm-create PROFILE=server
make vm-boot PROFILE=server
sleep 30

# Boot desktop ISO on server VM
make vm-bootiso PROFILE=server ISO=dist/qos-desktop.iso

# System will reboot into desktop ISO
```

### Scenario 4: Remote ISO Booting

```bash
# Build server ISO
make server

# Boot ISO on remote host
make bootiso-remote HOST=192.168.1.100

# With custom credentials
make bootiso-remote HOST=myhost.com PORT=2222 USER=root PASS=root

# Boot desktop ISO
make bootiso-remote HOST=192.168.1.100 ISO=dist/qos-desktop.iso
```

### Scenario 5: Full qos-install Workflow

```bash
# Build server
make server

# Create and boot VM
make vm-create PROFILE=server
make vm-boot PROFILE=server
sleep 30

# Install to disk
make vm-ssh PROFILE=server "qos-install --auto /dev/vda"

# Stop and reboot
make vm-stop PROFILE=server
sleep 5

# Boot from installed disk
make vm-boot PROFILE=server
sleep 30

# Verify installed system
make vm-ssh PROFILE=server "mount | grep 'on / '"
```

### Scenario 6: Test All VM Commands

```bash
# Build
make server

# Create
make vm-create PROFILE=server

# Help
make vm-help

# List
make vm-list

# Info
make vm-info PROFILE=server

# Boot
make vm-boot PROFILE=server
sleep 20

# List (running)
make vm-list

# SSH with command
make vm-ssh PROFILE=server "uname -a"

# Stop
make vm-stop PROFILE=server

# List (stopped)
make vm-list

# Delete
make vm-delete PROFILE=server
```

---

## Diagnostic Commands

### Check VM Status

```bash
# List VMs
make vm-list

# Detailed info
make vm-info PROFILE=server

# Check if running
VBoxManage list runningvms | grep qos-server

# All VMs
VBoxManage list vms | grep qos
```

### Monitor Boot

```bash
# Watch serial log
tail -f virtualbox/qos-server/serial.log

# Check for errors
tail -50 virtualbox/qos-server/serial.log | grep -i error
```

### SSH Testing

```bash
# Test connectivity
timeout 5 sshpass -p emo2500 ssh -o ConnectTimeout=3 -p 2222 emo@localhost whoami

# SSH with verbose
sshpass -p emo2500 ssh -vvv -o StrictHostKeyChecking=no -p 2222 emo@localhost "echo test"

# Copy file to VM (ssh cat pipe — Dropbear has no SFTP server for scp)
sshpass -p emo2500 ssh -p 2222 emo@localhost "cat > /tmp/test.iso" < /tmp/test.iso

# Show qos system info
sshpass -p emo2500 ssh -p 2222 emo@localhost "qos info"
```

### Verify bootiso

```bash
# Check in rootfs
ls -lh build/rootfs/usr/bin/bootiso

# Check kexec
ls -lh build/rootfs/usr/sbin/kexec

# Check kernel config
grep CONFIG_KEXEC build/generated/profiles/server/kernel/x86_64.config
```

---

## Cleanup

### Delete VMs

```bash
# Delete server
make vm-delete PROFILE=server

# Delete desktop
make vm-delete PROFILE=desktop

# List remaining
make vm-list
```

### Clean Build

```bash
# Force rootfs rebuild
make clean-rootfs

# Clean disk images
make clean-disk

# Full clean
make clean
```

---

## Troubleshooting

### Force Stop VM

```bash
VBoxManage controlvm qos-server poweroff
```

### Remove VM Completely

```bash
VBoxManage unregistervm qos-server --delete
```

### Check Disk Space

```bash
df -h virtualbox/
du -sh build/
```

### Check SSH Port

```bash
netstat -tlnp | grep 2222
```

---

## Performance Test

```bash
# Time VM creation
time make vm-create PROFILE=server

# Time VM boot
time make vm-boot PROFILE=server

# Time SSH connection
time sshpass -p emo2500 ssh -o ConnectTimeout=10 -p 2222 emo@localhost "uptime"
```

