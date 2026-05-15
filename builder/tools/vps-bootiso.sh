#!/usr/bin/env bash
# vps-bootiso.sh — Upload and/or run a QOS ISO on a remote VPS with rollback
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

VPS_HOST="${VPS_HOST:-}"
VPS_PORT="${VPS_PORT:-22}"
VPS_USER="${VPS_USER:-emo}"
VPS_PASS="${VPS_PASS:-emo2500}"
ISO_FILE="${ISO_FILE:-}"
REMOTE_ISO="${REMOTE_ISO:-/mnt/qos-state/qos-server.iso}"
VPS_TIMEOUT="${VPS_TIMEOUT:-600}"
VPS_RETRY_INTERVAL="${VPS_RETRY_INTERVAL:-5}"
VPS_BOOTISO_MODE="${VPS_BOOTISO_MODE:-all}"
EXPECTED_VERSION=""
LOCAL_ISO_SHA=""

_ssh() {
    sshpass -p "$VPS_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -p "$VPS_PORT" \
        "${VPS_USER}@${VPS_HOST}" "$@"
}

log()  { printf "${BLUE}[VPS]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
err()  { printf "${RED}[ERR]${NC} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }

usage() {
    cat <<EOF
${BLUE}vps-bootiso${NC} — Upload and/or run a QOS ISO on a VPS

${BLUE}Modes:${NC}
  VPS_BOOTISO_MODE=upload   Copy ISO to VPS and verify SHA256
  VPS_BOOTISO_MODE=run      Run already-uploaded ISO via bootiso
  VPS_BOOTISO_MODE=all      Upload then run (default)

${BLUE}Usage:${NC}
  make vps-upload-iso HOST=<ip> [ISO=dist/qos-server.iso] [REMOTE_ISO=/mnt/qos-state/qos-server.iso]
  make vps-run-iso HOST=<ip> [ISO=dist/qos-server.iso] [REMOTE_ISO=/mnt/qos-state/qos-server.iso]
  make vps-bootiso HOST=<ip> [ISO=dist/qos-server.iso]
EOF
}

extract_expected_version() {
    local tmp_rootfs
    tmp_rootfs="$(mktemp /tmp/qos-rootfs.XXXXXX.sfs)"
    xorriso -osirrox on -indev "$ISO_FILE" -extract /rootfs.sfs "$tmp_rootfs" >/dev/null 2>&1
    EXPECTED_VERSION="$(unsquashfs -cat "$tmp_rootfs" etc/qos/version 2>/dev/null | head -1)"
    rm -f "$tmp_rootfs"
    [[ -n "$EXPECTED_VERSION" ]] || { err "Could not extract version from $ISO_FILE"; exit 1; }
}

verify_connectivity() {
    log "Checking VPS connectivity..."
    if ! _ssh "echo ok" 2>/dev/null | grep -q ok; then
        err "Cannot reach VPS at $VPS_HOST:$VPS_PORT"
        exit 1
    fi
    ok "VPS reachable"
}

ensure_remote_storage() {
    _ssh "sudo sh -c 'mkdir -p /mnt/qos-state && (grep -q \" /mnt/qos-state \" /proc/mounts || mount /dev/vda3 /mnt/qos-state)'" 2>&1 || {
        warn "Could not ensure /mnt/qos-state is mounted; upload may fail"
    }
}

upload_iso() {
    [[ -f "$ISO_FILE" ]] || { err "ISO not found: $ISO_FILE"; exit 1; }
    LOCAL_ISO_SHA="$(sha256sum "$ISO_FILE" | awk '{print $1}')"
    extract_expected_version
    ensure_remote_storage

    local REMOTE_TMP="/tmp/.qos-iso-upload-$$.iso"

    log "Uploading ISO to $REMOTE_ISO ..."
    sshpass -p "$VPS_PASS" scp -O \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -P "$VPS_PORT" \
        "$ISO_FILE" \
        "${VPS_USER}@${VPS_HOST}:${REMOTE_TMP}" || {
        err "SCP upload failed"
        exit 1
    }

    log "Moving ISO to final location..."
    _ssh "sudo mv '$REMOTE_TMP' '$REMOTE_ISO' && sudo sync" || {
        err "Failed to move ISO to $REMOTE_ISO"
        _ssh "rm -f '$REMOTE_TMP'" 2>/dev/null || true
        exit 1
    }

    log "Verifying uploaded ISO checksum..."
    local remote_sha
    remote_sha="$(_ssh "sha256sum '$REMOTE_ISO' 2>/dev/null | cut -d' ' -f1" | tr -d '\r')"
    [[ "$remote_sha" = "$LOCAL_ISO_SHA" ]] || {
        err "Uploaded ISO checksum mismatch"
        err "Local:  $LOCAL_ISO_SHA"
        err "Remote: $remote_sha"
        exit 1
    }

    ok "ISO uploaded and verified"
    log "Remote ISO:  $REMOTE_ISO"
    log "Expected:    $EXPECTED_VERSION"
}

run_iso() {
    if [[ -f "$ISO_FILE" ]]; then
        extract_expected_version
    else
        warn "Local ISO not provided; booted version will not be compared"
    fi
    ensure_remote_storage

    _ssh "test -f '$REMOTE_ISO'" >/dev/null 2>&1 || {
        err "Remote ISO not found: $REMOTE_ISO"
        exit 1
    }

    local old_ip
    old_ip="$(_ssh "PATH=/usr/sbin:/sbin:/usr/bin:/bin ip -o -4 addr show scope global 2>/dev/null" | awk '$3=="inet" { print $4; exit }' || echo "unknown")"
    log "Current IP: $old_ip"

    log "Executing remote bootiso with panic=60..."
    timeout 30 sshpass -p "$VPS_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -p "$VPS_PORT" \
        "${VPS_USER}@${VPS_HOST}" \
        "sudo env BOOTISO_CMDLINE_EXTRA='panic=60' bootiso '$REMOTE_ISO'" >/dev/null 2>&1 || true
    log "bootiso triggered — VPS is rebooting into QOS ISO"

    log ""
    log "Waiting for VPS to come back with a valid IP (timeout: ${VPS_TIMEOUT}s)..."
    log ""

    local elapsed=0
    while [ "$elapsed" -lt "$VPS_TIMEOUT" ]; do
        sleep "$VPS_RETRY_INTERVAL"
        elapsed=$((elapsed + VPS_RETRY_INTERVAL))

        printf "\r  ${YELLOW}[%3ds]${NC} probing..." "$elapsed"
        if _ssh "echo ok" 2>/dev/null | grep -q ok; then
            local new_ip remote_report remote_version
            new_ip="$(_ssh "PATH=/usr/sbin:/sbin:/usr/bin:/bin ip -o -4 addr show scope global 2>/dev/null" | awk '$3=="inet" { print $4; exit }')"
            if [ -n "$new_ip" ]; then
                echo ""
                ok "VPS responded at ${elapsed}s — IP: $new_ip"
                echo ""
                remote_report="$(_ssh "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; printf 'INFO\n'; qos info; printf 'VERSION\n'; qos version; printf 'SEED\n'; cat /etc/qos/seed-source 2>/dev/null || true; test -f /run/qos/seed-reader.done && printf 'seed-reader: done\n'" 2>/dev/null || true)"
                printf '%s\n' "$remote_report"
                remote_version="$(printf '%s\n' "$remote_report" | awk '/^QOS build: / { print; exit }')"
                if [[ -n "$EXPECTED_VERSION" && "$remote_version" != "$EXPECTED_VERSION" ]]; then
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
                return 0
            fi
        fi
        printf "\r  ${YELLOW}[%3ds]${NC} waiting..." "$elapsed"
    done

    echo ""
    echo ""
    err "═══════════════════════════════════════════════════════════"
    err "TIMEOUT: VPS did not come back within ${VPS_TIMEOUT}s"
    err "The VPS may reboot back to the previous OS via panic=60."
    err "═══════════════════════════════════════════════════════════"
    exit 1
}

[[ -n "$VPS_HOST" ]] || { usage >&2; exit 1; }

case "$VPS_BOOTISO_MODE" in
    upload|run|all) ;;
    *) err "Unknown VPS_BOOTISO_MODE: $VPS_BOOTISO_MODE"; exit 1 ;;
esac

for cmd in sshpass ssh scp sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || { err "missing: $cmd"; exit 1; }
done

if [[ "$VPS_BOOTISO_MODE" != "run" ]]; then
    for cmd in xorriso unsquashfs; do
        command -v "$cmd" >/dev/null 2>&1 || { err "missing: $cmd"; exit 1; }
    done
fi

log "═══════════════════════════════════════════════════════════"
log "VPS Boot ISO"
log "═══════════════════════════════════════════════════════════"
log "Mode:        $VPS_BOOTISO_MODE"
log "Host:        $VPS_HOST:$VPS_PORT"
log "User:        $VPS_USER"
log "Remote ISO:  $REMOTE_ISO"
if [[ -n "$ISO_FILE" && -f "$ISO_FILE" ]]; then
    log "Local ISO:   $ISO_FILE ($(du -h "$ISO_FILE" | cut -f1))"
fi
log "Timeout:     ${VPS_TIMEOUT}s"
log ""

verify_connectivity

case "$VPS_BOOTISO_MODE" in
    upload)
        upload_iso
        ;;
    run)
        run_iso
        ;;
    all)
        upload_iso
        run_iso
        ;;
esac
