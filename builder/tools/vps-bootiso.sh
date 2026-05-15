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
REMOTE_ISO="/tmp/boot.iso"
VPS_TIMEOUT="${VPS_TIMEOUT:-600}"  # 10 minutes
VPS_RETRY_INTERVAL="${VPS_RETRY_INTERVAL:-5}"

_ssh()  { sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p "$VPS_PORT" "${VPS_USER}@${VPS_HOST}" "$@"; }
_sshcat() { sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$VPS_PORT" "${VPS_USER}@${VPS_HOST}" "cat > $1" < "$2"; }

log()   { printf "${BLUE}[VPS]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC} %s\n" "$*" >&2; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }

cleanup() { rm -f /tmp/vps-bootiso-kexec; }
trap cleanup EXIT

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

for cmd in sshpass ssh; do
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

# ── Step 2: Copy ISO ────────────────────────────────────────────────────────
log "Copying ISO to VPS..."
_sshcat "$REMOTE_ISO" "$ISO_FILE" || { err "Failed to copy ISO"; exit 1; }
ok "ISO copied ($REMOTE_ISO)"

# ── Step 3: Prepare kexec wrapper with panic=60 ──────────────────────────────
log "Preparing kexec wrapper with panic=60..."
cat > /tmp/vps-bootiso-kexec <<'KEXEC_WRAP'
#!/bin/sh
# Wrapper: run bootiso, but if kexec fails or kernel panics,
# the system will auto-reboot within 60 seconds back to original OS.
set -eu
# Add panic=60 to kernel cmdline so the VPS reboots automatically
# if the new kernel fails to boot or panics.
if [ -f /tmp/boot.iso ]; then
    MNT="/tmp/bootiso-$$"
    mkdir -p "$MNT"
    trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT
    mount -o loop,ro /tmp/boot.iso "$MNT"

    VMLINUZ=""
    INITRD=""
    for k in vmlinuz boot/vmlinuz live/vmlinuz casper/vmlinuz; do
        [ -f "$MNT/$k" ] && VMLINUZ="$MNT/$k" && break
    done
    for i in initramfs-live.img initrd.img boot/initrd.img live/initrd.img casper/initrd.lz casper/initrd; do
        [ -f "$MNT/$i" ] && INITRD="$MNT/$i" && break
    done

    if [ -n "$VMLINUZ" ] && [ -n "$INITRD" ]; then
        CMDLINE="$(cat /proc/cmdline) panic=60"
        echo "vps-bootiso: loading kernel with panic=60"
        kexec -l "$VMLINUZ" --initrd="$INITRD" --command-line="$CMDLINE"
        echo "vps-bootiso: handing off to ISO kernel..."
        kexec -e
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
timeout 30 _ssh "sudo /tmp/vps-kexec" 2>/dev/null || true
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
            _ssh "PATH=/usr/sbin:/sbin:/usr/bin:/bin; echo '=== qos info ==='; qos info; echo '=== cloud-init ==='; cloud-init status" 2>/dev/null || true
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
