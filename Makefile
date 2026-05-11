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

.PHONY: help full build-log build-grep kernel live qemu clean

help:
	@printf '%s\n' \
		'full         - build the live ISO (reuses existing kernel if present)' \
		'build-log    - run the full build and tee output to $(BUILD_LOG)' \
		'build-grep   - grep interesting lines from $(BUILD_LOG)' \
		'kernel       - rebuild the kernel explicitly' \
		'live         - boot the live ISO in QEMU (run scripts/qemu-host-net-up.sh first for tap mode)' \
		'qemu         - boot from the installed disk (run scripts/qemu-host-net-up.sh first for tap mode)' \
		'clean        - remove build outputs'

full:
	@BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) DROPBEAR_AUTHORIZED_KEYS_FILE=$(DROPBEAR_AUTHORIZED_KEYS_FILE) bash build.sh

build-log:
	@mkdir -p $(dir $(BUILD_LOG))
	@BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) DROPBEAR_AUTHORIZED_KEYS_FILE=$(DROPBEAR_AUTHORIZED_KEYS_FILE) bash -o pipefail -c 'bash build.sh 2>&1 | tee "$$1"' _ $(BUILD_LOG)

build-grep:
	@grep -E '^(error:|build complete:|rootfs staged|service configs staged|image assembled|Limine|Linux|s6|network:|dropbear:|btop:)' $(BUILD_LOG) || true

kernel:
	@BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) KERNEL_BUILD_DIR=$(ROOT)/build/kernel bash scripts/build-kernel.sh

live:
	@## Boot live ISO — extra disk (/dev/vda inside VM) is the install target.
	@## Workflow: make live → qos-install --auto /dev/vda → poweroff → make qemu
	@test -f dist/qos-x86_64.iso || { echo "ERROR: dist/qos-x86_64.iso not found. Run: make full"; exit 1; }
	@QEMU_MEMORY=$(QEMU_MEMORY) QEMU_CPUS=$(QEMU_CPUS) QEMU_NET_MODE=$(QEMU_NET_MODE) QEMU_BRIDGE_IFACE=$(QEMU_BRIDGE_IFACE) QEMU_HOSTFWD_PORT=$(QEMU_HOSTFWD_PORT) scripts/boot-image.sh --qemu-iso $(ROOT)/dist/qos-x86_64.iso

qemu:
	@## Boot from the installed disk (build/qemu/extra-disk.raw).
	@## Run 'make live' and 'qos-install' first.
	@QEMU_BOOT_DISK=installed QEMU_MEMORY=$(QEMU_MEMORY) QEMU_CPUS=$(QEMU_CPUS) QEMU_NET_MODE=$(QEMU_NET_MODE) QEMU_BRIDGE_IFACE=$(QEMU_BRIDGE_IFACE) QEMU_HOSTFWD_PORT=$(QEMU_HOSTFWD_PORT) scripts/boot-image.sh --qemu

clean:
	@rm -rf build dist/*.raw dist/*.iso
