# Waydroid Integration (AOSP Tier 1)

**Status:** Design only.
**Scope:** Replace the "Native AOSP Execution Host" feature in
`docs/NATIVE-AOSP-EXECUTION.md` with a Waydroid-based path. The
"native, no container" approach is parked per review §2.10 (tier 3).

This is **tier 1** of the three-tier reframing:

1. Tier 1 (this doc): Waydroid in an s6-managed container.
2. Tier 2 (research): Bionic-side single-APK loader.
3. Tier 3 (parked): Full native AOSP host.

---

## 1. Why Waydroid

- LXC-based, runs an unmodified LineageOS image. We do not maintain
  the AOSP tree.
- Wayland-native via `wayland-server` proxy → host compositor.
- 90% of the engineering is upstream. We integrate, we do not port.
- Honest about the cost: ~200MB RAM, ~600MB disk. That is acceptable
  for the `desktop` and `gaming` profiles, excluded from `server` /
  `k8s`.

## 2. Components

- `lxc` package + kernel modules (`CONFIG_USER_NS=y`,
  `CONFIG_PID_NS=y`, etc.). Most are already required for k3s and
  flatpak; see `KERNEL-SPLIT-PLAN.md`.
- `waydroid` package from Alpine community (when available; otherwise
  build from upstream tarball pinned by `qos.yaml`).
- A LineageOS system image fetched at first launch (not at build
  time — too large for the ISO).
- s6 service `waydroid-container` that runs the LXC container as the
  current user, not root.

## 3. State location

- Container rootfs and `/data`: `/var/lib/waydroid/` (state partition).
- Per-user home overlay: `~/.local/share/waydroid/`.
- `factory-reset.sh` policy: `/var/lib/waydroid/` is wiped. The
  download is large — surface a "keep Android image?" prompt or a
  `--keep-android` flag.

## 4. Profile integration

Available on `desktop` and `gaming` only. Add to `config/qos.yaml`:

```yaml
profiles:
  desktop:
    packages: [..., waydroid, lxc]
    services: [..., waydroid-container]
```

`server` and `k8s` profiles do not get waydroid (review §2.6).

## 5. Sequencing

1. Get LXC running cleanly on `desktop` profile under QEMU.
2. Add `waydroid init` step as a first-boot oneshot.
3. Wire `qos android start|stop|status` subcommand to the CLI router.
4. Hardware accel: pass `/dev/dri/*` into the container; verify on
   AMD + NVIDIA.
5. Document the Google-Play-out-of-the-box gap (we don't ship GApps).

## 6. What this gives up vs the original proposal

- Android apps run **in a container**, not as native Linux processes.
- `htop` on the host sees `lxc-init`, not individual app processes.
- Some Android sensor / camera HALs won't work; same caveats as
  Waydroid upstream.

This is the honest tradeoff. The "first-class Linux processes" claim
in `NATIVE-AOSP-EXECUTION.md` is not deliverable in 2026 by any team
this size. See review §2.10 for the full reasoning.
