# QOS Desktop VM — Fixes & Features

## Summary
All fixes applied to get the `qos` VM desktop GUI fully working in VirtualBox:
River compositor + Chromium with seamless mouse, keyboard, audio, and video playback.

---

## Files Modified

| File | Change |
|------|--------|
| `components/gpu-open-source/kernel/drm-open.conf` | GPU/audio/USB/VBoxGuest kernel config |
| `components/river/rootfs/usr/bin/qos-launch-desktop` | Udev triggers, ALSA unmute, vboxguest modprobe |
| `components/river/rootfs/root/.config/river/init` | Chromium auto-launch, VBoxClient, foot removed |
| `components/pipewire/s6/service-tree/pipewire-pulse/run` | New: pipewire-pulse s6 service |
| `components/pipewire/s6/s6-rc.d/pipewire-pulse/type` | New: s6 type for pipewire-pulse |
| `components/desktop-user/component.yaml` | Added vbox guest packages |
| `components/desktop-user/s6/service-tree/vboxservice/run` | New: VBoxService s6 service |
| `components/desktop-user/s6/s6-rc.d/vboxservice/type` | New: s6 type for VBoxService |
| `builder/pipeline/06-iso/build-iso.sh` | Removed `i8042.noaux` from cmdline |

---

## GPU / Display

| Fix | Detail |
|-----|--------|
| vmwgfx driver | `CONFIG_DRM_VMWGFX=y`, `CONFIG_DRM_VMWGFX_FBC=y` |
| VMware guest support | `CONFIG_HYPERVISOR_GUEST=y`, `CONFIG_VMWARE_VMCI=y` |
| Software renderer | `export WLR_RENDERER=pixman` — VirtualBox 3D/EGL fails with vmwgfx on Wayland |
| DRM modifiers off | `export WLR_DRM_NO_MODIFIERS=1`, `WLR_EGL_NO_MODIFIERS=1` |
| Module probe | `modprobe vmwgfx` (among others) in launch script |
| Resolution | Detected `1280x800@60` on `Virtual-1` connector |

---

## Mouse

| Fix | Detail |
|-----|--------|
| PS/2 mouse | Removed `i8042.noaux` from kernel cmdline |
| USB Tablet | Switched VBoxManage `--mouse usbtablet` for absolute positioning |
| vboxguest module | `CONFIG_VIRT_DRIVERS=y`, `CONFIG_VBOXGUEST=m` — provides `VirtualBox mouse integration` device |
| Guest Additions | `virtualbox-guest-additions` packages + VBoxClient |
| Seamless mouse | `VirtualBox_mouse_integration` (ABS_X/ABS_Y) eliminates capture prompt |
| Clipboard/DnD | `VBoxClient --clipboard`, `VBoxClient --draganddrop`, `VBoxClient --seamless` autostarted in River init |

---

## Keyboard

| Fix | Detail |
|-----|--------|
| PS/2 keyboard | Works via i8042 serio — AT Translated Set 2 keyboard (event3) |
| Udev coldplug | `udevadm trigger --action=add --subsystem-match=input` — was missing `ID_INPUT_KEYBOARD=1` on cold boot |
| River detection | Keyboard now shows as `keyboard-1-1-AT_Translated_Set_2_keyboard` |

---

## Audio

| Fix | Detail |
|-----|--------|
| AC'97 driver | `CONFIG_SND_INTEL8X0=y`, `CONFIG_SND_AC97_CODEC=y` — Intel 82801AA-ICH (0x8086:0x2415) |
| Udev coldplug | `udevadm trigger --action=add --subsystem-match=sound` — was missing `SOUND_FORM_FACTOR`, `ID_BUS` |
| ALSA unmute | `amixer set Master 100% unmute; amixer set PCM 100% unmute` in launch script |
| PipeWire Pulse | Created s6 service for `pipewire-pulse` — Chromium uses PulseAudio API |
| Sink created | `Built-in Audio Analog Stereo` via WirePlumber ALSA monitor |

---

## USB

| Fix | Detail |
|-----|--------|
| Host controllers | `CONFIG_USB_OHCI_HCD=y`, `CONFIG_USB_EHCI_HCD=y`, `*_PCI=y` |
| USB Tablet | Detected as `VirtualBox USB Tablet` with `ABS=3` (absolute X/Y) |

---

## Chromium

| Fix | Detail |
|-----|--------|
| Auto-launch | Starts as default app in River init (no foot terminal on boot) |
| Flags | `--ozone-platform=wayland --no-sandbox --test-type` + GPU/zero-copy flags |
| Shortcut | `Super+C` to relaunch, `Super+Return` for foot terminal |
| PulseAudio | Works via `pipewire-pulse` s6 service |

---

## Services (s6)

| Service | Source | Purpose |
|---------|--------|---------|
| `pipewire-pulse` | `components/pipewire/s6/` | PulseAudio compat for Chromium |
| `vboxservice` | `components/desktop-user/s6/` | VBoxService for host/guest integration |

---

## VirtualBox VM Settings

```
EFI:         on
RAM:         8 GB
CPUs:        4
GPU:         vmsvga (3D accelerated)
Pointing:    USB Tablet (seamless via vboxguest)
Keyboard:    PS/2
Audio:       Intel HD Audio (AC'97)
Network:     NAT + host port forwarding (SSH: 2222)
Storage:     dist/qos-desktop.iso (optical)
```

---

## Root Causes

1. **Keyboard not detected by River** — udev coldplug didn't set `ID_INPUT_KEYBOARD=1`. Using `udevadm trigger --action=add` (not `--action=change`) fixed it.

2. **No audio devices in PipeWire** — Same udev coldplug issue for sound subsystem. `--action=add --subsystem-match=sound` resolved it.

3. **No PulseAudio for Chromium** — `pipewire-pulse` was installed but not running. Created s6 service.

4. **Mouse capture prompt** — Without Guest Additions, VirtualBox can't confirm mouse integration. `CONFIG_VBOXGUEST` + `virtualbox-guest-additions` + `VBoxClient` provided full seamless mouse, clipboard, and drag-and-drop support.

5. **vboxguest module missing** — `CONFIG_VBOXGUEST` depends on `CONFIG_VIRT_DRIVERS=y` (parent menuconfig). Without it, the option gets silently dropped by `olddefconfig`.

6. **Rootfs cache stale** — Kernel modules built but not copied to rootfs because rootfs was reused from cache. Cache invalidation needed for module changes.

---

## Build Commands

```bash
# Full rebuild (after config changes)
rm -f build/rootfs/.qos-cache-tag build/kernel/build/.qos-kernel-cache-tag
make desktop

# VM control
VBoxManage startvm qos --type gui
VBoxManage controlvm qos poweroff

# SSH
sshpass -p 'root' ssh -p 2222 -o StrictHostKeyChecking=no root@localhost
```
