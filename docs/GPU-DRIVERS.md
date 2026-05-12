# GPU Drivers in QOS

**Status:** Schema landed. Kernel and rootfs wiring **not yet executed.**

## 1. Policy

GPU support is **profile-driven**:

- `server` — no GPU support. Kernel modules and firmware are pruned
  from the rootfs at build time. Cloud/headless VMs do not benefit.
- `desktop` — open-source stack: AMD (amdgpu, radeon), Intel (i915),
  Nouveau (open NVIDIA), VirtIO-GPU. Mesa + Vulkan userspace.
- **NVIDIA proprietary** — never in any profile. Licensing forbids
  baking it into the ISO. Planned as an *optional overlay* installed
  post-boot. See §5.

The declarative source is `config/qos.yaml` under
`profiles.<name>.gpu.{kernel_modules, firmware}`.

## 2. What the kernel needs

The current kernel has `CONFIG_DRM=n`. To support any GPU it needs
DRM and per-vendor modules. Recommended values (all `=m` so the
`mdev-coldplug` service can autoload only what the hardware requires):

```
CONFIG_DRM=m
CONFIG_DRM_AMDGPU=m
CONFIG_DRM_RADEON=m
CONFIG_DRM_I915=m
CONFIG_DRM_NOUVEAU=m
CONFIG_DRM_VIRTIO_GPU=m
CONFIG_DRM_KMS_HELPER=m
CONFIG_DRM_FBDEV_EMULATION=y    # text consoles on GPU
```

Plus firmware-loading prerequisites that may already be set:

```
CONFIG_FW_LOADER=y
CONFIG_EXTRA_FIRMWARE=""        # let userspace ship firmware
```

This is a **one-shot kernel config change** that invalidates the
kernel build cache (next `make kernel` will be 20-30 min).

## 3. What userspace needs

Already declared in `qos.yaml > profiles.desktop.packages`:

- `mesa`, `mesa-dri-gallium` — DRI userspace
- `mesa-vulkan-ati`, `mesa-vulkan-intel` — Vulkan ICDs
- `linux-firmware-amdgpu`, `linux-firmware-radeon`,
  `linux-firmware-i915`, `linux-firmware-nouveau` — firmware blobs
  (loaded by the kernel at module init)

Firmware tarballs are large (~200MB total upstream). Alpine packages
them per-vendor so we can take just what we need. The desktop image
gains roughly 60-80MB of firmware on top of the userspace stack.

## 4. Module pruning for `server`

The kernel ships every module it builds under
`/lib/modules/$KVER/kernel/`. To honor the `server` profile's "no GPU"
policy without a separate kernel build, `build-rootfs.sh` must prune
the directories listed in `profiles.server.gpu.kernel_modules` —
which is an empty list, meaning *prune everything under
`drivers/gpu/`*.

Pseudo:

```sh
keep="$(qos-manifest show profiles.$QOS_PROFILE.gpu.kernel_modules)"
if [ -z "$keep" ]; then
    rm -rf "$rootfs/lib/modules/$KVER/kernel/drivers/gpu"
fi
```

For `desktop` the listed module paths are kept; siblings under
`drivers/gpu/drm/` that are NOT in the list are pruned (e.g. ARM/Mali
drivers we never use on x86_64).

Disk savings on server: ~30-50MB depending on which DRM modules end
up built.

## 5. NVIDIA proprietary (separate overlay, not in base)

Constraints:

- NVIDIA's EULA is not Alpine-license-compatible. Cannot redistribute
  in our ISO.
- Module must match running kernel exactly.

Plan (no code yet):

1. `qos-nvidia install` subcommand fetches the NVIDIA open-kernel
   module source for the running kernel version from upstream and
   builds it locally. Pairs with the proprietary userspace driver
   fetched the same way.
2. Output goes into a `/lib/modules-nvidia/$KVER/` directory and a
   `nvidia.sfs` overlay mounted at boot via initramfs.
3. The overlay is a *state-partition asset*. Survives OTAs by being
   rebuilt against the new kernel as a post-OTA step.
4. Mesa userspace stays in `/usr/lib`; NVIDIA userspace goes into the
   overlay too so it does not contaminate the base image.

This is genuinely separate work, on the order of two weeks. Not on
the 2026 critical path unless explicitly requested.

## 6. Sequencing

1. **Now (done):** schema in `config/qos.yaml`; this doc; profile
   consolidation to server/desktop only.
2. **Next change ready to fire:** flip the kernel config symbols in
   `config/kernel/x86_64.config` and rebuild. ~25 min.
3. **After that:** add `linux-firmware-*` packages to apk install
   logic when `qos.yaml > profiles.desktop.packages` is honored by
   `build-rootfs.sh` (currently it still reads `config/apk/*` directly).
4. **Then:** add the module-pruning step to `build-rootfs.sh` per §4.
5. **Validate:** boot `make desktop` on real AMD hardware. Look for
   `amdgpu` in `lsmod` and `/dev/dri/card0`.
6. **Defer:** NVIDIA proprietary overlay per §5.

## 7. Not doing

- Per-profile kernel image (server gets a smaller kernel without DRM
  symbols). Possible, but requires kernel-variant build infra; the
  module-pruning approach reaches the same disk-savings outcome
  without a second kernel build.
- Wayland-only desktop without framebuffer console. We keep
  `FRAMEBUFFER_CONSOLE=y` so early-boot text still renders before
  DRM modules load.
- VESA / classic-fbdev paths. DRM is the only sanctioned graphics
  path. If a board doesn't have a DRM driver, the desktop profile
  won't work on it; the server profile will (no graphics needed).
