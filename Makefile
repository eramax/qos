SHELL := /bin/bash
.DEFAULT_GOAL := help

BUILD_MOCK ?= 0
BUILD_KERNEL_JOBS ?= 15
BUILD_TOOL_JOBS ?= 15
BUILD_LOG ?= build/logs/build.log
QEMU_IMAGE ?= dist/qos-x86_64.raw
QEMU_MEMORY ?= 1G
QEMU_CPUS ?= 2
QEMU_NET_MODE ?= tap
QEMU_BRIDGE_IFACE ?= auto
QEMU_HOSTFWD_PORT ?= none
QEMU_BOOT_DISK ?= primary  # primary or installed

ROOT := $(shell pwd -P)

.PHONY: help build full build-log build-grep rootfs services kernel initramfs boot-limine iso image boot qemu qwen2 smoke ssh-test clean

help:
	@printf '%s\n' \
		'build        - run the full build' \
		'full         - clean and run the full build from scratch' \
		'build-log    - run the full build and tee output to $(BUILD_LOG)' \
		'build-grep   - grep interesting lines from $(BUILD_LOG)' \
		'rootfs       - build the Alpine rootfs and staged service configs' \
		'services     - install staged service configs into an existing rootfs' \
		'kernel       - build the kernel only' \
		'initramfs    - build the initramfs only' \
		'boot-limine  - stage Limine plus kernel/initramfs into build/boot' \
		'iso          - build bootable live CD ISO' \
		'image        - assemble the raw disk image from existing payloads' \
		'boot         - boot live ISO in QEMU (requires make iso)' \
		'qemu         - boot raw disk image in QEMU (primary disk)' \
		'qemu2        - boot from installed disk (secondary disk)' \
		'smoke        - boot $(QEMU_IMAGE) and capture serial output to a log' \
		'ssh-test     - boot the image and SSH in to install/run btop' \
		'clean        - remove build outputs'

build:
	@$(MAKE) full

full:
	@BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) DROPBEAR_AUTHORIZED_KEYS_FILE=$(DROPBEAR_AUTHORIZED_KEYS_FILE) bash build.sh

build-log:
	@mkdir -p $(dir $(BUILD_LOG))
	@BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) DROPBEAR_AUTHORIZED_KEYS_FILE=$(DROPBEAR_AUTHORIZED_KEYS_FILE) bash -o pipefail -c 'bash build.sh 2>&1 | tee "$$1"' _ $(BUILD_LOG)

build-grep:
	@grep -E '^(error:|build complete:|rootfs staged|service configs staged|image assembled|Limine|Linux|s6|network:|dropbear:|btop:)' $(BUILD_LOG) || true

rootfs:
	@ROOTFS_DIR=$(ROOT)/build/rootfs bash scripts/build-rootfs.sh

services: rootfs
	@ROOTFS_DIR=$(ROOT)/build/rootfs bash scripts/install-services.sh

kernel:
	@BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) KERNEL_BUILD_DIR=$(ROOT)/build/kernel bash scripts/build-kernel.sh

initramfs: rootfs services
	@INITRAMFS_BUILD_DIR=$(ROOT)/build/initramfs ROOTFS_DIR=$(ROOT)/build/rootfs bash scripts/build-initramfs.sh

boot-limine: kernel initramfs
	@LIMINE_STAGE_DIR=$(ROOT)/build/boot KERNEL_BUILD_DIR=$(ROOT)/build/kernel INITRAMFS_BUILD_DIR=$(ROOT)/build/initramfs bash scripts/install-limine.sh

iso: boot-limine
	@ISO_OUTPUT_DIR=$(ROOT)/dist BOOT_STAGE_DIR=$(ROOT)/build/boot ROOTFS_DIR=$(ROOT)/build/rootfs bash scripts/build-iso.sh

image:
	@IMAGE_BUILD_DIR=$(ROOT)/build/image IMAGE_OUTPUT_DIR=$(ROOT)/dist ROOTFS_DIR=$(ROOT)/build/rootfs BOOT_STAGE_DIR=$(ROOT)/build/boot bash scripts/assemble-image.sh

boot:
	@echo "Booting raw disk image in QEMU (use 'make qemu' for ISO boot)..."
	@QEMU_BOOT_DISK=primary QEMU_MEMORY=$(QEMU_MEMORY) QEMU_CPUS=$(QEMU_CPUS) QEMU_NET_MODE=$(QEMU_NET_MODE) QEMU_BRIDGE_IFACE=$(QEMU_BRIDGE_IFACE) QEMU_HOSTFWD_PORT=$(QEMU_HOSTFWD_PORT) scripts/boot-image.sh --qemu $(QEMU_IMAGE)

qemu:
	@## Boot live ISO — extra disk (/dev/vda inside VM) is the install target.
	@## Workflow: make qemu → qos-install --auto /dev/vda → poweroff → make qemu2
	@test -f dist/qos-x86_64.iso || { echo "ERROR: dist/qos-x86_64.iso not found. Run: make iso"; exit 1; }
	@QEMU_MEMORY=$(QEMU_MEMORY) QEMU_CPUS=$(QEMU_CPUS) QEMU_NET_MODE=$(QEMU_NET_MODE) QEMU_BRIDGE_IFACE=$(QEMU_BRIDGE_IFACE) QEMU_HOSTFWD_PORT=$(QEMU_HOSTFWD_PORT) scripts/boot-image.sh --qemu-iso $(ROOT)/dist/qos-x86_64.iso

qemu2:
	@## Boot from the installed disk (build/qemu/extra-disk.raw).
	@## Run 'make qemu' and 'qos-install' first.
	@QEMU_BOOT_DISK=installed QEMU_MEMORY=$(QEMU_MEMORY) QEMU_CPUS=$(QEMU_CPUS) QEMU_NET_MODE=$(QEMU_NET_MODE) QEMU_BRIDGE_IFACE=$(QEMU_BRIDGE_IFACE) QEMU_HOSTFWD_PORT=$(QEMU_HOSTFWD_PORT) scripts/boot-image.sh --qemu $(QEMU_IMAGE)

smoke:
	@scripts/boot-image.sh --smoke $(QEMU_IMAGE)

ssh-test:
	@DROPBEAR_AUTHORIZED_KEYS_FILE=$(ROOT)/build/ssh-test/authorized_keys \
		SSH_TEST_PORT=2222 \
		BUILD_MOCK=$(BUILD_MOCK) \
		BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) \
		BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) \
		bash scripts/ssh-test.sh

clean:
	@rm -rf build dist/*.raw
