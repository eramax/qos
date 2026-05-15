#!/usr/bin/env bash
# bootiso-remote.sh — Copy ISO to remote host and boot via kexec
# Usage: bootiso-remote.sh [OPTIONS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults
REMOTE_HOST=""
REMOTE_PORT=22
REMOTE_USER="emo"
REMOTE_PASS="emo2500"
ISO_FILE=""
REMOTE_ISO_PATH="/tmp/boot.iso"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

usage() {
    cat <<EOF
${BLUE}bootiso-remote${NC} — Boot ISO on remote host via kexec

${BLUE}Usage:${NC}
  bootiso-remote.sh -h HOST [-p PORT] [-u USER] [-P PASS] [-i ISO] [-r REMOTE_PATH]

${BLUE}Options:${NC}
  -h HOST          Remote host IP or hostname (required)
  -p PORT          SSH port (default: 22)
  -u USER          SSH username (default: emo)
  -P PASS          SSH password (default: emo2500)
  -i ISO           Local ISO file path (default: dist/qos-server.iso)
  -r REMOTE_PATH   Remote destination path (default: /tmp/boot.iso)
  --help           Show this message

${BLUE}Examples:${NC}
  # Boot default server ISO
  bootiso-remote.sh -h 192.168.1.100

  # Boot desktop ISO with custom port
  bootiso-remote.sh -h myhost.com -p 2222 -i dist/qos-desktop.iso

  # Boot with custom credentials
  bootiso-remote.sh -h 192.168.1.50 -u admin -P mypass -i /path/to/custom.iso

EOF
}

log()   { printf "${BLUE}[BOOT]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h)
            REMOTE_HOST="$2"
            shift 2
            ;;
        -p)
            REMOTE_PORT="$2"
            shift 2
            ;;
        -u)
            REMOTE_USER="$2"
            shift 2
            ;;
        -P)
            REMOTE_PASS="$2"
            shift 2
            ;;
        -i)
            ISO_FILE="$2"
            shift 2
            ;;
        -r)
            REMOTE_ISO_PATH="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validation
[ -n "$REMOTE_HOST" ] || error "Host is required (-h)"

# Determine ISO file
if [ -z "$ISO_FILE" ]; then
    ISO_FILE="$PROJECT_ROOT/dist/qos-server.iso"
fi

[ -f "$ISO_FILE" ] || error "ISO not found: $ISO_FILE"

# Check for required tools
for cmd in sshpass ssh; do
    command -v "$cmd" >/dev/null 2>&1 || error "Required tool missing: $cmd"
done

log "═══════════════════════════════════════════════════════════"
log "bootiso-remote"
log "═══════════════════════════════════════════════════════════"
log "Host:        $REMOTE_HOST:$REMOTE_PORT"
log "User:        $REMOTE_USER"
log "ISO:         $ISO_FILE"
log "Remote:      $REMOTE_ISO_PATH"
log ""

# Copy ISO to remote host
log "Copying ISO to remote host..."
ISO_SIZE=$(du -h "$ISO_FILE" | cut -f1)
log "  Size: $ISO_SIZE"

sshpass -p "$REMOTE_PASS" ssh \
    -p "$REMOTE_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${REMOTE_USER}@${REMOTE_HOST}" \
    "cat > ${REMOTE_ISO_PATH}" < "$ISO_FILE" || error "Failed to copy ISO"

ok "ISO copied to $REMOTE_HOST:$REMOTE_ISO_PATH"

# Boot via bootiso command
log ""
log "Booting ISO on remote host..."
log "  Running: bootiso $REMOTE_ISO_PATH"
log ""

# Execute bootiso - this will hand off control, so we don't wait for it
sshpass -p "$REMOTE_PASS" ssh \
    -p "$REMOTE_PORT" \
    $SSH_OPTS \
    "${REMOTE_USER}@${REMOTE_HOST}" \
    "bootiso '$REMOTE_ISO_PATH'" \
    || true  # Don't fail if connection drops during kexec handoff

log ""
log "═══════════════════════════════════════════════════════════"
ok "bootiso executed on $REMOTE_HOST"
log "System is handing off to ISO kernel now..."
log "═══════════════════════════════════════════════════════════"
log ""
log "The system will reboot into the ISO environment."
log "On shutdown/reboot, it will return to the installed system."
