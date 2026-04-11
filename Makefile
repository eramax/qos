SHELL := /bin/bash
.DEFAULT_GOAL := help

BUILD_MOCK ?= 0
BUILD_KERNEL_JOBS ?= 15
BUILD_TOOL_JOBS ?= 15
BUILD_LOG ?= build/logs/build.log
QEMU_IMAGE ?= dist/qos-x86_64.raw
QEMU_MEMORY ?= 256M
QEMU_HOSTFWD_PORT ?= none

ROOT := $(shell pwd -P)

.PHONY: help build build-log build-grep rootfs services kernel initramfs boot-limine image qemu smoke clean

help:
	@printf '%s\n' \
		'build        - run the full build' \
		'build-log    - run the full build and tee output to $(BUILD_LOG)' \
		'build-grep   - grep interesting lines from $(BUILD_LOG)' \
		'rootfs       - build the Alpine rootfs and staged service configs' \
		'services     - install staged service configs into an existing rootfs' \
		'kernel       - build the kernel only' \
		'initramfs    - build the initramfs only' \
		'boot-limine  - stage Limine plus kernel/initramfs into build/boot' \
		'image        - assemble the raw disk image' \
		'qemu         - boot $(QEMU_IMAGE) in QEMU with live serial output' \
		'smoke        - boot $(QEMU_IMAGE) and capture serial output to a log' \
		'clean        - remove build outputs'

build:
	@BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) bash build.sh

build-log:
	@mkdir -p $(dir $(BUILD_LOG))
	@BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) bash -o pipefail -c 'bash build.sh 2>&1 | tee "$$1"' _ $(BUILD_LOG)

build-grep:
	@grep -E '^(error:|build complete:|rootfs staged|service configs staged|image assembled|Limine|Linux|s6|network:|dropbear:|btop:)' $(BUILD_LOG) || true

rootfs:
	@ROOTFS_DIR=$(ROOT)/build/rootfs bash scripts/build-rootfs.sh

services: rootfs
	@ROOTFS_DIR=$(ROOT)/build/rootfs bash scripts/install-services.sh

kernel:
	@KERNEL_BUILD_DIR=$(ROOT)/build/kernel bash scripts/build-kernel.sh

initramfs: rootfs services
	@INITRAMFS_BUILD_DIR=$(ROOT)/build/initramfs ROOTFS_DIR=$(ROOT)/build/rootfs bash scripts/build-initramfs.sh

boot-limine: kernel initramfs
	@LIMINE_STAGE_DIR=$(ROOT)/build/boot KERNEL_BUILD_DIR=$(ROOT)/build/kernel INITRAMFS_BUILD_DIR=$(ROOT)/build/initramfs bash scripts/install-limine.sh

image: boot-limine
	@IMAGE_BUILD_DIR=$(ROOT)/build/image IMAGE_OUTPUT_DIR=$(ROOT)/dist ROOTFS_DIR=$(ROOT)/build/rootfs BOOT_STAGE_DIR=$(ROOT)/build/boot bash scripts/assemble-image.sh

qemu:
	@QEMU_MEMORY=$(QEMU_MEMORY) QEMU_HOSTFWD_PORT=$(QEMU_HOSTFWD_PORT) scripts/boot-image.sh --qemu $(QEMU_IMAGE)

smoke:
	@scripts/boot-image.sh --smoke $(QEMU_IMAGE)

clean:
	@rm -rf build dist/*.raw
