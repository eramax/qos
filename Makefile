SHELL := /bin/bash
.DEFAULT_GOAL := help

BUILD_MOCK ?= 0
BUILD_KERNEL_JOBS ?= 15
BUILD_TOOL_JOBS ?= 15
BUILD_LOG ?= build/logs/build.log
QEMU_MEMORY ?= 1G
QEMU_CPUS ?= 2
QEMU_NET_MODE ?= tap
QEMU_BRIDGE_IFACE ?= br0
QEMU_HOSTFWD_PORT ?= none
QEMU_IMAGE ?= dist/qos-x86_64.raw

ROOT := $(shell pwd -P)
KERNEL_IMAGE := $(ROOT)/build/kernel/arch/x86/boot/bzImage

.PHONY: help full full-container server desktop live-server live-desktop rootfs clean-rootfs clean-disk manifest-gen manifest-diff ram-check build-log build-grep kernel live qemu clean

QOS_PROFILE ?= server

help:
	@printf '%s\n' \
		'full            - build the live ISO using QOS_PROFILE (default: server)' \
		'full-container  - build inside a pinned Podman container (see Containerfile)' \
		'server          - build with QOS_PROFILE=server   (headless + k3s, no GPU)' \
		'desktop         - build with QOS_PROFILE=desktop  (Wayland + Chromium + Steam + open-source GPU)' \
		'live-server     - build the server ISO and boot it in QEMU' \
		'live-desktop    - build the desktop ISO and boot it in QEMU (2G RAM)' \
		'manifest-gen    - generate package/service/layout files from config/qos.yaml' \
		'manifest-diff   - diff generator output against the source-of-truth files' \
		'ram-check       - boot ISO in QEMU and assert RAM usage <= profile budget' \
		'build-log       - run the full build and tee output to $(BUILD_LOG)' \
		'build-grep      - grep interesting lines from $(BUILD_LOG)' \
		'kernel          - rebuild the kernel explicitly' \
		'rootfs          - rebuild the rootfs (apk install) explicitly; honors QOS_PROFILE' \
		'clean-rootfs    - wipe the rootfs cache so the next build re-runs apk install' \
		'clean-disk      - wipe the install target disk + OVMF NVRAM (forces ISO boot)' \
		'live            - boot the live ISO in QEMU (run scripts/qemu-host-net-up.sh first for tap mode)' \
		'qemu            - boot from the installed disk (run scripts/qemu-host-net-up.sh first for tap mode)' \
		'clean           - remove build outputs'

full:
	@QOS_PROFILE=$(QOS_PROFILE) BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) DROPBEAR_AUTHORIZED_KEYS_FILE=$(DROPBEAR_AUTHORIZED_KEYS_FILE) bash build.sh

full-container:
	@QOS_PROFILE=$(QOS_PROFILE) BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) DROPBEAR_AUTHORIZED_KEYS_FILE=$(DROPBEAR_AUTHORIZED_KEYS_FILE) bash scripts/build-in-container.sh

# Per-profile shortcuts. Each just re-invokes `make full` with the
# matching QOS_PROFILE; the profile drives package selection and the
# s6 overlay copied in by install-services.sh. See config/qos.yaml.
server:
	@$(MAKE) full QOS_PROFILE=server

desktop:
	@$(MAKE) full QOS_PROFILE=desktop

# Build + boot in one shot. Each target depends on its profile build,
# then re-invokes `make live` with profile-appropriate QEMU memory.
# Desktop gets 2G by default because Wayland + Chromium does not fit in
# the server's 1G — override with QEMU_MEMORY=… if needed.
live-server: server
	@$(MAKE) live

live-desktop: desktop
	@QEMU_DISPLAY=$(if $(QEMU_DISPLAY),$(QEMU_DISPLAY),gtk) $(MAKE) live QEMU_MEMORY=$(if $(filter 1G,$(QEMU_MEMORY)),2G,$(QEMU_MEMORY))

ram-check:
	@QOS_PROFILE=$(QOS_PROFILE) bash scripts/qos-ram-check.sh

manifest-gen:
	@bash scripts/qos-manifest.sh gen

manifest-diff:
	@bash scripts/qos-manifest.sh diff

build-log:
	@mkdir -p $(dir $(BUILD_LOG))
	@BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) DROPBEAR_AUTHORIZED_KEYS_FILE=$(DROPBEAR_AUTHORIZED_KEYS_FILE) bash -o pipefail -c 'bash build.sh 2>&1 | tee "$$1"' _ $(BUILD_LOG)

build-grep:
	@grep -E '^(error:|build complete:|rootfs staged|service configs staged|image assembled|Limine|Linux|s6|network:|dropbear:|btop:)' $(BUILD_LOG) || true

kernel:
	@BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) KERNEL_BUILD_DIR=$(ROOT)/build/kernel bash scripts/build-kernel.sh

# Force-rebuild the rootfs for the current QOS_PROFILE. The full build
# reuses this cache automatically on subsequent runs (same profile).
rootfs:
	@BUILD_FORCE_ROOTFS=1 QOS_PROFILE=$(QOS_PROFILE) ROOTFS_DIR=$(ROOT)/build/rootfs bash scripts/build-rootfs.sh

clean-rootfs:
	@chmod -R u+w $(ROOT)/build/rootfs 2>/dev/null || true
	@rm -rf $(ROOT)/build/rootfs
	@echo "removed build/rootfs (next build will reinstall packages)"

# Wipe the install target disk so the next `make live` boots the ISO
# fresh. Use this when a previous qos-install run wrote a bootloader
# to vda1 that OVMF picks instead of the CD.
clean-disk:
	@rm -f $(ROOT)/build/qemu/extra-disk.raw $(ROOT)/build/qemu/OVMF_VARS.fd
	@echo "removed extra-disk.raw and OVMF NVRAM (next make live boots from ISO)"

live:
	@## Boot live ISO — extra disk (/dev/vda inside VM) is the install target.
	@## Workflow: make live → qos-install --auto /dev/vda → poweroff → make qemu
	@test -f dist/qos-x86_64.iso || { echo "ERROR: dist/qos-x86_64.iso not found. Run: make full"; exit 1; }
	@QEMU_DISPLAY=$(QEMU_DISPLAY) QEMU_MEMORY=$(QEMU_MEMORY) QEMU_CPUS=$(QEMU_CPUS) QEMU_NET_MODE=$(QEMU_NET_MODE) QEMU_BRIDGE_IFACE=$(QEMU_BRIDGE_IFACE) QEMU_HOSTFWD_PORT=$(QEMU_HOSTFWD_PORT) scripts/boot-image.sh --qemu-iso $(ROOT)/dist/qos-x86_64.iso

qemu:
	@## Boot from the installed disk (build/qemu/extra-disk.raw).
	@## Run 'make live' and 'qos-install' first.
	@QEMU_BOOT_DISK=installed QEMU_MEMORY=$(QEMU_MEMORY) QEMU_CPUS=$(QEMU_CPUS) QEMU_NET_MODE=$(QEMU_NET_MODE) QEMU_BRIDGE_IFACE=$(QEMU_BRIDGE_IFACE) QEMU_HOSTFWD_PORT=$(QEMU_HOSTFWD_PORT) scripts/boot-image.sh --qemu

clean:
	@rm -rf build dist/*.raw dist/*.iso
