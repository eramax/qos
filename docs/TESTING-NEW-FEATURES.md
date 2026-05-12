# Testing the New Features

How to verify the work landed by `FEATURE-REVIEW-AND-IDEAS.md` steps 1–13:
qos CLI router, container build, qos.yaml generator, RAM budget check,
profile system, mdev cold-boot probe, k3s overlay, OTA consolidation,
test framework extraction.

Each section is independently runnable and fails fast. Run top-to-bottom
the first time; cherry-pick afterwards.

---

## 1. Static checks (no build needed, ~5s)

```sh
bash -n scripts/qos.sh scripts/qos-manifest.sh scripts/qos-ram-check.sh \
        scripts/qos-ota.sh scripts/build-in-container.sh \
        scripts/lib/test-common.sh \
        scripts/ota-prepare.sh scripts/ota-switch.sh \
        scripts/ota-rollback.sh scripts/ota-healthcheck.sh

bash scripts/qos.sh help
bash scripts/qos.sh profile current     # → server
bash scripts/qos.sh profile list        # → server / desktop / gaming / k8s
```

## 2. Manifest generator (no build needed, ~1s)

```sh
make manifest-gen          # writes build/generated/{apk,image}/*
make manifest-diff         # must report all four "ok"
                           # if it errors, config/qos.yaml drifted from config/

bash scripts/qos-manifest.sh profiles
bash scripts/qos-manifest.sh packages --profile k8s
bash scripts/qos-manifest.sh packages --profile gaming
bash scripts/qos-manifest.sh show image.size      # → 384M
```

`manifest-diff` is the regression gate. As long as it stays green, the
declarative manifest can reproduce the legacy input files byte-for-byte
(modulo cosmetic `description` strings in `layout.json`).

## 3. OTA consolidation didn't regress (no build, ~2s)

```sh
bash tests/test_ota_flow.sh        # must print "ok"
```

Exercises all four `ota-*.sh` wrappers → `qos-ota.sh` subcommands.

## 4. Build the ISO (~10–30 min depending on kernel cache)

```sh
make full                  # default: BUILD_MOCK=1, fast path
BUILD_MOCK=0 make full     # real ISO

# Containerized variant — first run builds the builder image (~5 min):
make full-container
```

After either, `dist/qos-x86_64.iso` should exist.

## 5. Boot the live ISO in QEMU

```sh
make live                  # boots dist/qos-x86_64.iso
# login: root / root
```

## 6. On-target smoke tests (run inside the booted VM)

```sh
qos help                          # router enumerates subcommands
qos version                       # reads /etc/qos/build-version
qos profile current               # → server (factory default)
qos verify                        # placeholder; prints image identity
qos-ota help                      # OTA subcommands
ls /usr/lib/qos-test-common.sh    # confirms test framework is staged
qos test --quick                  # slimmed qos-test.sh
```

`qos manifest …` on-target only works if `config/qos.yaml` is staged into
the rootfs (currently not done; the manifest is a build-time tool). If
you want it available on the running system, that's a one-line add to
`install-services.sh`.

## 7. mdev cold-boot probe ran

Inside the VM:

```sh
cat /run/qos/mdev-coldplug.done    # must exist
ls /etc/mdev.conf                  # auto-generated $MODALIAS rule
```

If busybox in this build doesn't include `mdev`, the service no-ops and
the marker still appears — that is intentional. The service is a
cold-plug probe, not a hotplug-daemon replacement (review §2.2).

## 8. Profile system

```sh
# In the booted VM:
cat /etc/qos/profile               # → server (written at build time)
qos profile set desktop
qos profile current                # → desktop

# k3s overlay should NOT be in the server image:
ls /etc/s6/service-tree/k3s-server 2>&1   # → "No such file or directory"
```

To verify the overlay path actually copies, rebuild with the k8s profile:

```sh
make clean
make full QOS_PROFILE=k8s
# then in the new image:
ls /etc/s6/service-tree/k3s-server/run    # exists
```

## 9. RAM budget check (built ISO + KVM required)

```sh
make ram-check                    # default budget: 64MB for server profile

QEMU_MEMORY=256 QOS_PROFILE=server make ram-check
QOS_RAM_BUDGET_KB=80000 make ram-check         # raise budget temporarily
```

Host prerequisites: `qemu-system-x86_64`, `sshpass`, `ssh`, KVM, and OVMF
firmware at `/usr/share/ovmf/OVMF.fd`. If your distro puts OVMF
elsewhere, edit the path near the top of `scripts/qos-ram-check.sh`.

## 10. What is NOT testable yet, and why

- **dm-verity / `qos verify` proper:** placeholder only. Gated on the
  questions in `VERITY-KEY-CUSTODY.md`.
- **Waydroid, WebView, mkosi, kernel split:** design docs only; no code
  to exercise.
- **Gaming / desktop profile boot:** the package overlay schema is in
  `qos.yaml`, but the build does **not** yet install profile-specific
  apk packages — only the `config/s6/profile-overlays/<name>/`
  directory gets copied. So `QOS_PROFILE=desktop make full` today
  produces a *server* image with `desktop` written to `/etc/qos/profile`.
  That is deliberate scaffolding; profile→apk wiring is a follow-up step.

## Fast smoke (the line I run before declaring it green)

```sh
bash -n scripts/*.sh scripts/lib/*.sh && \
  make manifest-diff && \
  bash tests/test_ota_flow.sh && \
  make full && \
  echo "static + generator + ota + build: OK"
```

If that exits 0, the additive surface is healthy. From there it is QEMU
boot and on-target smoke per §5–9.
