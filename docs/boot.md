Here is a feature description you can use for your QOS documentation or design spec:

***

## Feature: `boot <img.iso>`

### Overview
The `boot` command allows the user to boot into a given ISO image file directly from the running QOS, without requiring a USB drive or modifying the bootloader configuration. After the ISO session ends and the machine performs a real reboot, the system returns to the normal Limine + hard disk boot automatically.

### How It Works

Under the hood, the feature uses **`kexec`** (Kernel Execute) — a Linux kernel mechanism that lets the currently running kernel hand off execution directly to a new kernel loaded from disk. This skips BIOS/UEFI firmware, hardware reinitialization, and the Limine bootloader entirely. [en.wikipedia](https://en.wikipedia.org/wiki/Kexec)

The flow is:

1. **Mount** the ISO file as a loopback device [wiki.archlinux](https://wiki.archlinux.org/title/Kexec)
2. **Extract** the kernel (`vmlinuz`) and initrd from the ISO
3. **Load** the new kernel into memory via `kexec -l`
4. **Execute** the handoff via `kexec -e` (or `systemctl kexec` for a graceful shutdown) [wiki.archlinux](https://wiki.archlinux.org/title/Kexec)
5. The ISO environment **boots fresh** — QOS is gone from memory, hardware is not re-initialized
6. When the ISO session ends and the machine **reboots normally**, Limine takes over and boots the hard disk as usual [en.wikipedia](https://en.wikipedia.org/wiki/Kexec)

### Implementation Notes

```bash
# Step 1: Mount the ISO
mount -o loop img.iso /mnt/iso

# Step 2: Load its kernel + initrd via kexec
kexec -l /mnt/iso/boot/vmlinuz \
      --initrd=/mnt/iso/boot/initrd.img \
      --command-line="boot=live"

# Step 3: Graceful handoff
systemctl kexec
```

### Requirements
- Linux kernel compiled with `CONFIG_KEXEC=y` [wiki.archlinux](https://wiki.archlinux.org/title/Kexec)
- The ISO must contain a standard `vmlinuz` + `initrd` (true for all standard live Linux ISOs)
- Root/sudo privileges to call `kexec`

### Behavior Summary

| Scenario | Behavior |
|---|---|
| User runs `boot img.iso` | QOS mounts ISO, loads its kernel via kexec, hands off immediately |
| ISO session is running | Fully isolated environment, QOS is not in memory |
| User shuts down ISO session | Machine performs a real reboot |
| After real reboot | Limine boots normally from hard disk |

### Limitations
- Some hardware (notably **GPU/display drivers**) may not reset cleanly since firmware POST is skipped; unloading the GPU driver before `kexec` (e.g., `modprobe -r nvidia_drm`) mitigates this [wiki.archlinux](https://wiki.archlinux.org/title/Kexec)
- Requires the ISO to be a **live bootable image** with an accessible kernel and initrd
- If Secure Boot is enforced, only **signed kernels** can be loaded via kexec [en.wikipedia](https://en.wikipedia.org/wiki/Kexec)