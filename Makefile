.DEFAULT_GOAL := help

BUILD_MOCK ?= 0
BUILD_KERNEL_JOBS ?= 15
BUILD_TOOL_JOBS ?= 15
BUILD_LOG ?= build/logs/build.log
QEMU_IMAGE ?= dist/qos-x86_64.raw
QEMU_MEMORY ?= 256M

.PHONY: help build build-log build-grep boot smoke clean

help:
	@printf '%s\n' \
		'build      - run the full build' \
		'build-log  - run the full build and tee output to $(BUILD_LOG)' \
		'build-grep - grep interesting lines from $(BUILD_LOG)' \
		'boot       - boot $(QEMU_IMAGE) in QEMU with live serial output' \
		'smoke      - boot $(QEMU_IMAGE) and capture serial output to a log' \
		'clean      - remove build outputs'

build:
	@BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) bash build.sh

build-log:
	@mkdir -p $(dir $(BUILD_LOG))
	@BUILD_MOCK=$(BUILD_MOCK) BUILD_KERNEL_JOBS=$(BUILD_KERNEL_JOBS) BUILD_TOOL_JOBS=$(BUILD_TOOL_JOBS) bash -o pipefail -c 'bash build.sh 2>&1 | tee "$$1"' _ $(BUILD_LOG)

build-grep:
	@grep -E '^(error:|build complete:|rootfs staged|service configs staged|image assembled|Limine|Linux|s6|network:|dropbear:|btop:)' $(BUILD_LOG) || true

boot:
	@QEMU_MEMORY=$(QEMU_MEMORY) scripts/boot-image.sh --qemu $(QEMU_IMAGE)

smoke:
	@scripts/boot-image.sh --smoke $(QEMU_IMAGE)

clean:
	@rm -rf build dist/*.raw
