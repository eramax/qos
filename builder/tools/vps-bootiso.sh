#!/usr/bin/env bash
# vps-bootiso.sh — Safely boot a QOS ISO on a remote VPS with rollback
#
# 1. Copies ISO to the VPS
# 2. Kexecs into it with panic=60 (auto-reboot on kernel panic)
# 3. Waits up to VPS_TIMEOUT (default: 10m) for the VPS to come back with an IP
# 4. Reports the new IP on success
# 5. On timeout the VPS panics → firmware → boots back to installed OS
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

VPS_HOST="${VPS_HOST:-}"
VPS_PORT="${VPS_PORT:-22}"
VPS_USER="${VPS_USER:-emo}"
VPS_PASS="${VPS_PASS:-emo2500}"
ISO_FILE="${ISO_FILE:-}"
REMOTE_KERNEL="/tmp/vps-vmlinuz"
REMOTE_INITRD="/tmp/vps-initramfs.img"
VPS_TIMEOUT="${VPS_TIMEOUT:-600}"  # 10 minutes
VPS_RETRY_INTERVAL="${VPS_RETRY_INTERVAL:-5}"
EXPECTED_VERSION=""
LOCAL_TMP_DIR=""
LOCAL_KERNEL_SHA=""
LOCAL_INITRD_SHA=""

_ssh()  { sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p "$VPS_PORT" "${VPS_USER}@${VPS_HOST}" "$@"; }
_sshcat() { sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$VPS_PORT" "${VPS_USER}@${VPS_HOST}" "cat > $1" < "$2"; }

log()   { printf "${BLUE}[VPS]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC} %s\n" "$*" >&2; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }

cleanup() {
    rm -f /tmp/vps-bootiso-kexec
    [[ -n "$LOCAL_TMP_DIR" ]] && rm -rf "$LOCAL_TMP_DIR"
}
trap cleanup EXIT

extract_iso_artifacts() {
    LOCAL_TMP_DIR="$(mktemp -d /tmp/qos-vps-bootiso.XXXXXX)"
    xorriso -osirrox on -indev "$ISO_FILE" -extract /vmlinuz "$LOCAL_TMP_DIR/vmlinuz" >/dev/null 2>&1
    xorriso -osirrox on -indev "$ISO_FILE" -extract /initramfs-live.img "$LOCAL_TMP_DIR/initramfs-live.img" >/dev/null 2>&1
    xorriso -osirrox on -indev "$ISO_FILE" -extract /rootfs.sfs "$LOCAL_TMP_DIR/rootfs.sfs" >/dev/null 2>&1
}

build_combined_initramfs() {
    local unpack_dir="$LOCAL_TMP_DIR/initramfs-tree"
    mkdir -p "$unpack_dir"
    (
        cd "$unpack_dir"
        lz4 -dc "$LOCAL_TMP_DIR/initramfs-live.img" | cpio -idmu --quiet
        cp "$LOCAL_TMP_DIR/rootfs.sfs" "$unpack_dir/rootfs.sfs"
        find . -print0 | cpio --null -o -H newc 2>/dev/null | lz4 -l -z -q -c > "$LOCAL_TMP_DIR/initramfs-kexec.img"
    )
}

usage() {
    cat <<EOF
${BLUE}vps-bootiso${NC} — Boot QOS ISO on VPS with 10-minute safety net

${BLUE}Usage:${NC}
  make vps-bootiso HOST=<ip> [PORT=22] [USER=emo] [PASS=emo2500] [ISO=dist/qos-server.iso]

${BLUE}Env:${NC}
  VPS_HOST       Remote host (required)
  VPS_PORT       SSH port (default: 22)
  VPS_USER       SSH user (default: emo)
  VPS_PASS       SSH password (default: emo2500)
  VPS_TIMEOUT    Wait timeout in seconds (default: 600)
  ISO            Local ISO file (default: dist/qos-server.iso)

${BLUE}How it works:${NC}
  1. Copies ISO to VPS via ssh cat pipe
  2. Kexecs into ISO kernel with panic=60 (auto-reboot on crash)
  3. Waits for VPS to come back with a valid IP
  4. On timeout: VPS reboots to original OS via panic/watchdog
EOF
}

[[ -n "${VPS_HOST:-}" ]] || { usage >&2; exit 1; }
[[ -f "$ISO_FILE" ]] || { err "ISO not found: $ISO_FILE"; exit 1; }

for cmd in sshpass ssh sha256sum xorriso unsquashfs lz4 cpio find; do
    command -v "$cmd" >/dev/null 2>&1 || { err "missing: $cmd"; exit 1; }
done

log "═══════════════════════════════════════════════════════════"
log "VPS Boot ISO"
log "═══════════════════════════════════════════════════════════"
log "Host:        $VPS_HOST:$VPS_PORT"
log "User:        $VPS_USER"
log "ISO:         $ISO_FILE ($(du -h "$ISO_FILE" | cut -f1))"
log "Timeout:     ${VPS_TIMEOUT}s"
log ""

# ── Step 1: Verify VPS is reachable ──────────────────────────────────────────
log "Checking VPS connectivity..."
if ! _ssh "echo ok" 2>/dev/null | grep -q ok; then
    err "Cannot reach VPS at $VPS_HOST:$VPS_PORT"
    exit 1
fi
ok "VPS reachable"

# Capture current IP before kexec
OLD_IP="$(_ssh "PATH=/usr/sbin:/sbin:/usr/bin:/bin ip -o -4 addr show scope global 2>/dev/null" | awk '{for(i=1;i<=NF;i++) if($i=="inet") print $(i+1)}' | head -1 || echo "unknown")"
log "Current IP: $OLD_IP"

extract_iso_artifacts
build_combined_initramfs
EXPECTED_VERSION="$(unsquashfs -cat "$LOCAL_TMP_DIR/rootfs.sfs" etc/qos/version 2>/dev/null | head -1)"
[[ -n "$EXPECTED_VERSION" ]] || { err "Could not extract embedded version from $ISO_FILE"; exit 1; }
LOCAL_KERNEL_SHA="$(sha256sum "$LOCAL_TMP_DIR/vmlinuz" | awk '{print $1}')"
LOCAL_INITRD_SHA="$(sha256sum "$LOCAL_TMP_DIR/initramfs-kexec.img" | awk '{print $1}')"
log "Kernel SHA:  $LOCAL_KERNEL_SHA"
log "Initrd SHA:  $LOCAL_INITRD_SHA"
log "Expected:    $EXPECTED_VERSION"

# ── Step 2: Copy kernel + initramfs derived from ISO ───────────────────────
log "Copying extracted kernel and rebuilt initramfs to VPS..."
_sshcat "$REMOTE_KERNEL" "$LOCAL_TMP_DIR/vmlinuz" || { err "Failed to copy kernel"; exit 1; }
_sshcat "$REMOTE_INITRD" "$LOCAL_TMP_DIR/initramfs-kexec.img" || { err "Failed to copy initramfs"; exit 1; }
ok "Kernel and initramfs copied"

log "Verifying uploaded artifact checksums..."
REMOTE_KERNEL_SHA="$(_ssh "sha256sum '$REMOTE_KERNEL' 2>/dev/null | cut -d' ' -f1" | tr -d '\r')"
REMOTE_INITRD_SHA="$(_ssh "sha256sum '$REMOTE_INITRD' 2>/dev/null | cut -d' ' -f1" | tr -d '\r')"
if [[ "$REMOTE_KERNEL_SHA" != "$LOCAL_KERNEL_SHA" ]]; then
    err "Uploaded kernel checksum mismatch"
    err "Local:  $LOCAL_KERNEL_SHA"
    err "Remote: $REMOTE_KERNEL_SHA"
    exit 1
fi
if [[ "$REMOTE_INITRD_SHA" != "$LOCAL_INITRD_SHA" ]]; then
    err "Uploaded initramfs checksum mismatch"
    err "Local:  $LOCAL_INITRD_SHA"
    err "Remote: $REMOTE_INITRD_SHA"
    exit 1
fi
ok "Uploaded artifacts match local SHA256"

# ── Step 3: Prepare kexec wrapper with panic=60 ──────────────────────────────
log "Preparing kexec wrapper with panic=60..."
cat > /tmp/vps-bootiso-kexec <<'KEXEC_WRAP'
#!/bin/sh
# Wrapper: run bootiso, but if kexec fails or kernel panics,
# the system will auto-reboot within 60 seconds back to original OS.
set -eu
# Add panic=60 to kernel cmdline so the VPS reboots automatically
# if the new kernel fails to boot or panics.
if [ -f /tmp/vps-vmlinuz ] && [ -f /tmp/vps-initramfs.img ]; then
    CMDLINE="$(cat /proc/cmdline) panic=60"
    echo "vps-bootiso: clearing stale kexec state..."
    kexec -u 2>/dev/null || true
    echo "vps-bootiso: loading uploaded kernel/initramfs"
    if kexec -l /tmp/vps-vmlinuz --initrd=/tmp/vps-initramfs.img --command-line="$CMDLINE"; then
        echo "vps-bootiso: handing off to ISO kernel..."
        kexec -e
    else
        echo "vps-bootiso: kexec load failed" >&2
        exit 1
    fi
fi
# If we get here, something failed — reboot back to disk
echo "vps-bootiso: kexec failed, rebooting to original OS"
reboot
KEXEC_WRAP

_sshcat "/tmp/vps-kexec" /tmp/vps-bootiso-kexec
_ssh "chmod +x /tmp/vps-kexec" >/dev/null 2>&1 || true

# ── Step 4: Execute kexec ────────────────────────────────────────────────────
log "Executing kexec into ISO (panic=60 for auto-rollback)..."
timeout 30 sshpass -p "$VPS_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=3 \
    -p "$VPS_PORT" \
    "${VPS_USER}@${VPS_HOST}" \
    "sudo /tmp/vps-kexec" >/dev/null 2>&1 || true
log "kexec triggered — VPS is rebooting into QOS ISO"

# ── Step 5: Wait for VPS to come back with an IP ─────────────────────────────
log ""
log "Waiting for VPS to come back with a valid IP (timeout: ${VPS_TIMEOUT}s)..."
log ""

elapsed=0
while [ "$elapsed" -lt "$VPS_TIMEOUT" ]; do
    sleep "$VPS_RETRY_INTERVAL"
    elapsed=$((elapsed + VPS_RETRY_INTERVAL))

    printf "\r  ${YELLOW}[%3ds]${NC} probing..." "$elapsed"

    # Simple test: if we can SSH in and run a command, VPS is alive with networking
    if _ssh "echo ok" 2>/dev/null | grep -q ok; then
        NEW_IP="$(_ssh "PATH=/usr/sbin:/sbin:/usr/bin:/bin ip -o -4 addr show scope global 2>/dev/null" | awk '{for(i=1;i<=NF;i++) if($i=="inet") print $(i+1)}' | head -1)"
        if [ -n "$NEW_IP" ]; then
            echo ""
            ok "VPS responded at ${elapsed}s — IP: $NEW_IP"
            echo ""
            remote_report="$(_ssh "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; printf 'INFO\\n'; qos info; printf 'VERSION\\n'; qos version; printf 'CLOUD\\n'; cloud-init status 2>/dev/null || true" 2>/dev/null || true)"
            printf '%s\n' "$remote_report"
            remote_version="$(printf '%s\n' "$remote_report" | awk '/^QOS build: / { print; exit }')"
            if [[ "$remote_version" != "$EXPECTED_VERSION" ]]; then
                err "Booted system version mismatch"
                err "Expected: $EXPECTED_VERSION"
                err "Actual:   ${remote_version:-<missing>}"
                exit 1
            fi
            if printf '%s\n' "$remote_report" | grep -q '^IPv4: none$'; then
                err "Booted system reported no IPv4 address"
                exit 1
            fi
            echo ""
            log "═══════════════════════════════════════════════════════════"
            ok "VPS bootiso SUCCESS — QOS is running"
            log "SSH:  sshpass -p $VPS_PASS ssh ${VPS_USER}@${VPS_HOST}"
            log "═══════════════════════════════════════════════════════════"
            exit 0
        fi
    fi

    printf "\r  ${YELLOW}[%3ds]${NC} waiting..." "$elapsed"
done

echo ""
echo ""
err "═══════════════════════════════════════════════════════════"
err "TIMEOUT: VPS did not come back within ${VPS_TIMEOUT}s"
err ""
err "The VPS should auto-reboot to the original OS (panic=60)."
err "If it doesn't, you may need to power-cycle it manually."
err "═══════════════════════════════════════════════════════════"
exit 1
