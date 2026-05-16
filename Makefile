SHELL := /bin/bash
.DEFAULT_GOAL := help
.SECONDEXPANSION:

BUILD_MOCK ?= 0
BUILD_KERNEL_JOBS ?= 15
BUILD_TOOL_JOBS ?= 15
BUILD_LOG ?= build/logs/build.log
QEMU_MEMORY ?= 1G
QEMU_CPUS ?= 2
QEMU_NET_MODE ?= tap
QEMU_BRIDGE_IFACE ?= br0
QEMU_HOSTFWD_PORT ?= 2222
QEMU_IMAGE ?= dist/qos-x86_64.raw

ROOT := $(shell pwd -P)
KERNEL_IMAGE := $(ROOT)/build/kernel/arch/x86/boot/bzImage

.PHONY: help full full-container server desktop live-server live-desktop run rootfs clean-rootfs clean-disk resolve-profile ram-check build-log build-grep kernel live qemu bootiso-remote bootiso-help vps-upload-iso vps-run-iso vps-bootiso vm-help vm-create vm-boot vm-stop vm-delete vm-ssh vm-bootiso vm-list vm-info clean

QOS_PROFILE ?= server
RUN_PROFILE ?= $(word 2,$(MAKECMDGOALS))

help:
	@printf '%s\n' \
		'full         - build the live ISO using QOS_PROFILE (default: server)' \
		'full-container  - build inside a pinned Podman container (see Containerfile)' \
		'<profile>       - build using profiles/<profile>.yaml (example: make edge)' \
		'server          - build with QOS_PROFILE=server   (headless + k3s, no GPU)' \
		'desktop         - build with QOS_PROFILE=desktop  (Wayland + Chromium + Steam + open-source GPU)' \
		'run <profile>   - build profile, then execute its resolved qemu.command' \
		'resolve-profile - stage the selected profile into build/generated/profiles/<name>' \
		'live-server     - build the server ISO and boot it in QEMU' \
		'live-desktop    - build the desktop ISO and boot it in QEMU (2G RAM)' \
		'ram-check       - boot ISO in QEMU and assert RAM usage <= profile budget' \
		'build-log       - run the full build and tee output to $(BUILD_LOG)' \
		'build-grep      - grep interesting lines from $(BUILD_LOG)' \
		'kernel          - rebuild the kernel explicitly' \
		'rootfs          - rebuild the rootfs (apk install) explicitly; honors QOS_PROFILE' \
		'clean-rootfs    - wipe the rootfs cache so the next build re-runs apk install' \
		'clean-disk      - wipe the install target disk + OVMF NVRAM (forces ISO boot)' \
		'live         - boot the live ISO in QEMU (run builder/tools/qemu-host-net-up.sh first for tap mode)' \
		'qemu         - boot from the installed disk (run builder/tools/qemu-host-net-up.sh first for tap mode)' \
		'bootiso-help    - show bootiso-remote usage (copy ISO to host and boot)' \
		'vps-upload-iso HOST=<ip> [PORT=22] [USER=emo] [PASS=emo2500] - upload ISO to VPS only' \
		'vps-run-iso HOST=<ip> [PORT=22] [USER=emo] [PASS=emo2500] - run previously uploaded ISO on VPS' \
		'vps-bootiso HOST=<ip> [PORT=22] [USER=emo] [PASS=emo2500] - upload ISO then run it on VPS' \
		'vm-help         - show VirtualBox VM management commands' \
		'vm-create PROFILE=<profile> - create VirtualBox VM (server|desktop)' \
		'vm-boot PROFILE=<profile>   - start and boot VM' \
		'vm-stop PROFILE=<profile>   - stop running VM' \
		'vm-delete PROFILE=<profile> - delete VM and disk' \
		'vm-ssh PROFILE=<profile>    - SSH into VM' \
		'vm-bootiso PROFILE=<profile> ISO=<iso> - boot ISO on VM via bootiso' \
		'vm-list              - list all QOS VMs' \
		'vm-info PROFILE=<profile> - show VM configuration' \
		'clean           - remove build outputs'

full:
	@QOS_PROFILE=$(QOS_PROFILE) BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) DROPBEAR_AUTHORIZED_KEYS_FILE=$(DROPBEAR_AUTHORIZED_KEYS_FILE) bash builder/build.sh

full-container:
	@QOS_PROFILE=$(QOS_PROFILE) BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) DROPBEAR_AUTHORIZED_KEYS_FILE=$(DROPBEAR_AUTHORIZED_KEYS_FILE) bash builder/tools/build-in-container.sh

# Per-profile shortcuts. Each just re-invokes `make full` with the
# matching QOS_PROFILE; the profile drives package selection.
server:
	@$(MAKE) full QOS_PROFILE=server

desktop:
	@$(MAKE) full QOS_PROFILE=desktop

# `make run <profile>` passes <profile> as a second goal. In run-mode we
# consume that goal as a no-op so Make does not execute a build target.
ifneq ($(filter run,$(MAKECMDGOALS)),)
ifneq ($(RUN_PROFILE),)
$(eval .PHONY: $(RUN_PROFILE))
$(eval $(RUN_PROFILE):;@:)
endif
endif

# Generic profile target: `make <profile>` maps to profiles/<profile>.yaml.
# Keep this after explicit targets so built-ins (help/clean/live/...) win.
%:
	@test -f "$(ROOT)/profiles/$@.yaml" || { echo "No rule to make target '$@'"; exit 2; }
	@$(MAKE) full QOS_PROFILE=$@

# Build + boot in one shot. Each target depends on its profile build,
# then re-invokes `make live` with profile-appropriate QEMU memory.
# Desktop gets 2G by default because Wayland + Chromium does not fit in
# the server's 1G — override with QEMU_MEMORY=… if needed.
live-server: server
	@$(MAKE) live QOS_PROFILE=server

live-desktop: desktop
	@QEMU_DISPLAY=$(if $(QEMU_DISPLAY),$(QEMU_DISPLAY),gtk) $(MAKE) live QOS_PROFILE=desktop QEMU_MEMORY=$(if $(filter 1G,$(QEMU_MEMORY)),2G,$(QEMU_MEMORY))

run:
	@test -n "$(RUN_PROFILE)" || { echo "usage: make run <profile>"; exit 2; }
	@test -f "$(ROOT)/profiles/$(RUN_PROFILE).yaml" || { echo "unknown profile: $(RUN_PROFILE)"; exit 2; }
	@test -f "$(ROOT)/dist/qos-$(RUN_PROFILE).iso" || { echo "missing ISO: dist/qos-$(RUN_PROFILE).iso (build first with: make $(RUN_PROFILE))"; exit 2; }
	@cmd="$$(bash builder/resolve.sh qemu --profile $(RUN_PROFILE))"; \
	echo "running profile '$(RUN_PROFILE)' with: $$cmd"; \
	bash -lc "$$cmd"

ram-check:
	@QOS_PROFILE=$(QOS_PROFILE) bash builder/tools/qos-ram-check.sh

resolve-profile:
	@rm -rf $(ROOT)/build/generated/profiles/$(QOS_PROFILE)
	@bash builder/resolve.sh stage --profile $(QOS_PROFILE) --out-dir $(ROOT)/build/generated/profiles/$(QOS_PROFILE)

build-log:
	@mkdir -p $(dir $(BUILD_LOG))
	@BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) DROPBEAR_AUTHORIZED_KEYS_FILE=$(DROPBEAR_AUTHORIZED_KEYS_FILE) bash -o pipefail -c 'bash builder/build.sh 2>&1 | tee "$$1"' _ $(BUILD_LOG)

build-grep:
	@grep -E '^(error:|build complete:|rootfs staged|service configs staged|image assembled|Limine|Linux|s6|network:|dropbear:|btop:)' $(BUILD_LOG) || true

kernel:
	@BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) KERNEL_BUILD_DIR=$(ROOT)/build/kernel bash builder/pipeline/02-kernel/build-kernel.sh

qemu-build:
	@bash builder/tools/build-qemu.sh

# Force-rebuild the rootfs for the current QOS_PROFILE. The full build
# reuses this cache automatically on subsequent runs (same profile).
rootfs:
	@$(MAKE) resolve-profile QOS_PROFILE=$(QOS_PROFILE)
	@BUILD_FORCE_ROOTFS=1 QOS_PROFILE=$(QOS_PROFILE) APK_PACKAGES_FILE=$(ROOT)/build/generated/profiles/$(QOS_PROFILE)/apk/packages.txt APK_REPOSITORIES_FILE=$(ROOT)/build/generated/profiles/$(QOS_PROFILE)/apk/repositories ROOTFS_DIR=$(ROOT)/build/rootfs bash builder/pipeline/01-rootfs/build-rootfs.sh

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
	@## Workflow: make live → qos-install --auto /dev/vda → reboot → make qemu
	@test -f dist/qos-$(QOS_PROFILE).iso || { echo "ERROR: dist/qos-$(QOS_PROFILE).iso not found. Run: make full QOS_PROFILE=$(QOS_PROFILE)"; exit 1; }
	@QEMU_DISPLAY=$(QEMU_DISPLAY) QEMU_MEMORY=$(QEMU_MEMORY) QEMU_CPUS=$(QEMU_CPUS) QEMU_NET_MODE=$(QEMU_NET_MODE) QEMU_BRIDGE_IFACE=$(QEMU_BRIDGE_IFACE) QEMU_HOSTFWD_PORT=$(QEMU_HOSTFWD_PORT) builder/tools/boot-image.sh --qemu-iso $(ROOT)/dist/qos-$(QOS_PROFILE).iso

qemu:
	@## Boot from the installed disk (build/qemu/extra-disk.raw).
	@## Run 'make live' and 'qos-install' first.
	@QEMU_BOOT_DISK=installed QEMU_MEMORY=$(QEMU_MEMORY) QEMU_CPUS=$(QEMU_CPUS) QEMU_NET_MODE=$(QEMU_NET_MODE) QEMU_BRIDGE_IFACE=$(QEMU_BRIDGE_IFACE) QEMU_HOSTFWD_PORT=$(QEMU_HOSTFWD_PORT) builder/tools/boot-image.sh --qemu

bootiso-help:
	@bash builder/tools/bootiso-remote.sh --help

bootiso-remote:
	@test -n "$(HOST)" || { echo "Usage: make bootiso-remote HOST=<host> [PORT=<port>] [USER=<user>] [PASS=<pass>] [ISO=<iso>]"; echo "Example: make bootiso-remote HOST=192.168.1.100"; exit 1; }
	@ISO_FILE="$${ISO:-dist/qos-server.iso}"; \
	test -f "$$ISO_FILE" || { echo "ISO not found: $$ISO_FILE"; exit 1; }; \
	bash builder/tools/bootiso-remote.sh \
		-h "$(HOST)" \
		-p "$${PORT:-22}" \
		-u "$${USER:-root}" \
		-P "$${PASS:-root}" \
		-i "$$ISO_FILE"

vps-upload-iso:
	@test -n "$(HOST)" || { echo "Usage: make vps-upload-iso HOST=<ip> [PORT=22] [USER=emo] [PASS=emo2500] [ISO=dist/qos-server.iso]"; exit 1; }
	@VPS_BOOTISO_MODE=upload \
	VPS_HOST="$(HOST)" \
	VPS_PORT="$${PORT:-22}" \
	VPS_USER="$${USER:-emo}" \
	VPS_PASS="$${PASS:-emo2500}" \
	ISO_FILE="$${ISO:-dist/qos-server.iso}" \
	REMOTE_ISO="$${REMOTE_ISO:-/mnt/qos-state/qos-server.iso}" \
	bash builder/tools/vps-bootiso.sh

vps-run-iso:
	@test -n "$(HOST)" || { echo "Usage: make vps-run-iso HOST=<ip> [PORT=22] [USER=emo] [PASS=emo2500] [ISO=dist/qos-server.iso]"; exit 1; }
	@VPS_BOOTISO_MODE=run \
	VPS_HOST="$(HOST)" \
	VPS_PORT="$${PORT:-22}" \
	VPS_USER="$${USER:-emo}" \
	VPS_PASS="$${PASS:-emo2500}" \
	ISO_FILE="$${ISO:-dist/qos-server.iso}" \
	REMOTE_ISO="$${REMOTE_ISO:-/mnt/qos-state/qos-server.iso}" \
	bash builder/tools/vps-bootiso.sh

vps-bootiso:
	@test -n "$(HOST)" || { echo "Usage: make vps-bootiso HOST=<ip> [PORT=22] [USER=emo] [PASS=emo2500] [ISO=dist/qos-server.iso]"; echo "Example: make vps-bootiso HOST=x.x.x.x"; exit 1; }
	@VPS_BOOTISO_MODE=all \
	VPS_HOST="$(HOST)" \
	VPS_PORT="$${PORT:-22}" \
	VPS_USER="$${USER:-emo}" \
	VPS_PASS="$${PASS:-emo2500}" \
	ISO_FILE="$${ISO:-dist/qos-server.iso}" \
	REMOTE_ISO="$${REMOTE_ISO:-/mnt/qos-state/qos-server.iso}" \
	bash builder/tools/vps-bootiso.sh

vm-help:
	@bash builder/tools/vm-manage.sh help

vm-create:
	@bash builder/tools/vm-manage.sh create $(PROFILE)

vm-boot:
	@bash builder/tools/vm-manage.sh boot $(PROFILE)

vm-stop:
	@bash builder/tools/vm-manage.sh stop $(PROFILE)

vm-delete:
	@bash builder/tools/vm-manage.sh delete $(PROFILE)

vm-ssh:
	@bash builder/tools/vm-manage.sh ssh $(PROFILE)

vm-bootiso:
	@bash builder/tools/vm-manage.sh bootiso $(PROFILE) $(ISO)

vm-list:
	@bash builder/tools/vm-manage.sh list

vm-info:
	@bash builder/tools/vm-manage.sh info $(PROFILE)

clean:
	@chmod -R u+w build 2>/dev/null || true
	@rm -rf build dist/*.raw dist/*.iso
