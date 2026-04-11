# qos

Minimal Alpine-style x86_64 server distro with:

- UEFI-only boot via Limine
- immutable `ext4` rootfs
- `s6` / `s6-rc` supervision
- Alpine `apk` packages
- `Dropbear` for SSH
- `nftables` as the only firewall backend
- image-based A/B OTA support

## Current progress

- The image build pipeline works end to end.
- The disk image is assembled into `dist/qos-x86_64.raw`.
- The guest boots through OVMF, Limine, kernel, initramfs, and `s6-linux-init`.
- Rootfs staging, Limine staging, initramfs generation, and image assembly are scripted.
- A `Makefile` is now available for short commands.
- Build commands and source URLs are recorded in `build/build.manifest`.

## Remaining work

- Re-run the guest after the latest service-path fixes.
- Verify DHCP comes up reliably on the guest interface.
- Verify `apk update` works from inside the VM.
- Install and run `btop` in the guest.
- Finish polishing the boot-time service tree and any remaining host-key/network startup edge cases.

## Build

Use the Makefile:

```bash
make build
```

Verbose build with logs:

```bash
make build-log
```

## Boot

Boot in QEMU with live serial output:

```bash
QEMU_HOSTFWD_PORT=none make boot
```

Smoke boot with log capture:

```bash
make smoke
```

## Useful commands

Tail the recorded build log:

```bash
sed -n '1,200p' build/logs/build.log
```

Filter the build log for important lines:

```bash
make build-grep
```

Run the guest image directly:

```bash
QEMU_HOSTFWD_PORT=none scripts/boot-image.sh --qemu dist/qos-x86_64.raw
```
