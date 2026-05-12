# mkosi Migration

**Status:** Design only.
**Goal:** Replace `build.sh` + `scripts/build-rootfs.sh` +
`scripts/assemble-image.sh` with `mkosi.conf` drop-ins, profile by
profile. Pairs with the Podman-containerized build (already landed).

See review §2.11.

---

## 1. Why mkosi (and why not yet)

- It owns image lifecycle: rootfs assembly, partitioning, signing,
  initrd, kernel-cmdline injection, A/B layout. We currently
  reimplement each of these in shell.
- It plays well with dm-verity (`Verity=yes`) — relevant for
  `VERITY-KEY-CUSTODY.md`.
- It expects systemd. We use s6. The integration point is just
  "image building" — mkosi produces a rootfs, we plug s6 into it the
  same way we already do. mkosi does *not* need to be aware of s6.

The reason this is design-only today: we have no parity test. We need
to prove mkosi can build a byte-equivalent server image before
removing any of the current shell pipeline.

## 2. Migration order (one profile at a time)

1. **`server`** first. Smallest, simplest, best-tested.
2. **`k8s`** next. Same family, only differs in packages + services.
3. **`desktop`** last among ship profiles. Needs the most plumbing
   (drivers, Wayland, Chromium).
4. **`gaming`** rides on `desktop`.

Each step ships behind `BUILD_TOOL=mkosi` while the default stays
`BUILD_TOOL=shell`. Flip only after both produce equivalent images for
two consecutive releases.

## 3. Where `qos.yaml` fits

`qos.yaml` is **not** mkosi's input format. mkosi reads
`mkosi.conf` + drop-ins. `qos.yaml` lives above mkosi and *generates*
mkosi drop-ins.

```
config/qos.yaml
     │
     ▼
scripts/qos-manifest.sh emits:
     - build/generated/apk/*       (today)
     - build/generated/image/*     (today)
     - build/generated/mkosi/*.conf (new, future)
     ▼
mkosi reads generated/mkosi/*.conf
     ▼
artifact in dist/
```

This is the same "generator first, authoritative later" pattern we
used for packages and layout. The build pipeline can read either the
generated mkosi configs or the legacy shell-input files.

## 4. Hard gates

- mkosi produces a byte-equivalent `server` image for two releases
  before we drop `scripts/build-rootfs.sh`.
- `make full` keeps working throughout. mkosi is a *parallel* code
  path until parity is proven.
- Reproducibility: pin `mkosi` version in `Containerfile`. Floating
  versions of an image-building tool defeat the purpose.

## 5. What we keep regardless

- `scripts/install-services.sh` — s6 wiring is ours, mkosi doesn't
  know about s6.
- `scripts/install-limine.sh` — mkosi has its own bootloader support
  but Limine is not in it. Keep our installer.
- The Podman builder image. mkosi runs *inside* it.

## 6. Not doing in the migration

- Switching to systemd. mkosi will run inside the builder image; the
  *target* image still runs s6.
- Switching package manager. We stay on apk.
- Changing the A/B layout. mkosi supports it; we keep ours bit-exact.
