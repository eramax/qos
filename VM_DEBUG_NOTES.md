# VM Debug Notes

## Task

Get the `qos` VM to boot the desktop image and show the GUI, not just a text console.

## What I learned

- The live ISO boot problem is fixed.
- The VM now boots far enough to mount `rootfs.sfs` from `/dev/sr0`.
- VirtualBox networking is working with `nat` + `virtio` NIC type.
- The guest now gets a DHCP lease on `10.0.2.15`.
- The VM window is created by VirtualBox, but the guest is still dropping to a text console instead of starting the desktop.
- The current blocker is not the kernel, ISO boot, or networking.
- The desktop startup path is still not being reached from the real boot sequence.

## Things already fixed

- Live ISO scan now checks `/dev/sr*`.
- Early init now mounts `/proc`, `/sys`, `/dev`, and `/run` before reading `/proc/cmdline`.
- Kernel config now includes the needed storage drivers for VirtualBox booting.
- The VM NIC was switched from Intel E1000 emulation to `virtio`.
- Guest DHCP now succeeds.
- Desktop launch scripts were added and updated to load `virtio_gpu` instead of the invalid `virtio-gpu` name.

## Current suspicion

- The desktop launcher changes may not be landing in the exact boot path that `init` uses.
- `tty1` still appears to be starting a plain `getty` path in the guest logs.
- The final missing piece is likely in the rootfs staging or the generated `inittab` path, not in the compositor itself.

## How I am testing

1. Rebuild the desktop image with `make desktop`.
2. Boot the VM in GUI mode with VirtualBox.
3. Watch the serial log in `build/screens/qos-serial.log`.
4. Verify these milestones in order:
   - live ISO finds `rootfs.sfs`
   - guest mounts live rootfs
   - networking gets a DHCP lease
   - desktop launcher starts on `tty1`
   - compositor starts
5. If GUI still does not appear, inspect the staged rootfs files in `build/rootfs` and the generated profile under `build/generated/profiles/desktop`.

## Commands Used

### Build

```bash
make desktop
make clean-rootfs
make clean
```

### VirtualBox

```bash
VBoxManage showvminfo qos --machinereadable
VBoxManage controlvm qos poweroff
VBoxManage startvm qos --type gui
VBoxManage startvm qos --type headless
VBoxManage modifyvm qos --nic1 nat --nictype1 virtio
VBoxManage modifyvm qos --firmware efi
```

### Log inspection

```bash
tail -n 120 build/screens/qos-serial.log
tail -f build/screens/qos-serial.log
```

### Common verification checks

```bash
rg -n "qos-river|qos-sway|starting river|starting sway|/dev/dri/card0|tty1" build/screens/qos-serial.log
rg -n "tty1::respawn:/usr/bin/qos-launch-desktop|qos-launch-desktop" build/rootfs build/generated/profiles/desktop
```

## Files I changed or inspected most

- `builder/pipeline/06-iso/build-iso.sh`
- `builder/pipeline/03-initrmd/mkinitfs.conf`
- `components/kernel/kernel/x86_64.config`
- `components/river/rootfs/etc/profile.d/qos-river.sh`
- `components/sway/rootfs/etc/profile.d/qos-sway.sh`
- `components/river/s6/service-tree/getty-tty1/run`
- `components/desktop-user/rootfs/etc/inittab`
- `components/river/rootfs/usr/bin/qos-launch-desktop`
- `build/rootfs/etc/inittab`
- `build/generated/profiles/desktop/rootfs/etc/s6/service-tree/getty-tty1/run`
- `build/screens/qos-serial.log`

## Next check

- Confirm whether `components/desktop-user/rootfs/etc/inittab` is copied into the final staged rootfs.
- If it is not, fix the staging step so the desktop profile overrides `tty1`.
- Reboot the VM and verify the serial log shows the desktop launcher instead of plain `login` on `tty1`.
