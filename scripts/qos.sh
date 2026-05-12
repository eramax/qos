#!/bin/sh
# qos - umbrella CLI dispatching to per-feature qos-* tools.
#
# This is an adapter, not a rewrite. Each subcommand execs the existing
# standalone tool so behavior stays identical. See docs/FEATURE-REVIEW-AND-IDEAS.md
# (section 2.5) for the design rationale.

set -eu

PROG="qos"
PROFILE_FILE="/etc/qos/profile"

# Discover where the qos-* siblings live. On an installed system they are in
# /usr/bin or /usr/local/bin. In the repo they are in scripts/ alongside this
# file with a .sh suffix.
self_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
candidates="$self_dir /usr/local/bin /usr/bin /bin"

find_tool() {
    name="$1"
    for d in $candidates; do
        if [ -x "$d/$name" ]; then
            printf '%s\n' "$d/$name"
            return 0
        fi
        if [ -x "$d/$name.sh" ]; then
            printf '%s\n' "$d/$name.sh"
            return 0
        fi
    done
    return 1
}

usage() {
    cat <<EOF
Usage: $PROG <command> [args...]

Commands:
  install [...]        Install QOS to a disk           (qos-install)
  capability [...]     Manage service capabilities     (qos-capability)
  cluster [...]        Cluster management              (qos-cluster)
  expand [...]         Expand state partition          (qos-expand)
  test [...]           Run on-target test suite        (qos-test)
  e2e [...]            Run full end-to-end suite       (qos-e2e-full)
  ota [...]            A/B OTA orchestration           (qos-ota)

  build [args...]      Build the distribution (host-side, repo-only)
  manifest <sub>       Work with config/qos.yaml (gen, diff, validate)
  profile <sub>        Show or set the active workload profile
  verify               Show image integrity status (placeholder)

  version              Print qos CLI / build version
  help                 Show this message

Examples:
  $PROG install --auto /dev/vda
  $PROG cluster nodes
  $PROG manifest gen
  $PROG profile current

This umbrella is an adapter over the per-feature qos-* tools; running
those tools directly works exactly the same way.
EOF
}

run_tool() {
    name="$1"
    shift
    tool="$(find_tool "$name" || true)"
    if [ -z "$tool" ]; then
        printf 'error: %s not found on PATH or alongside %s\n' "$name" "$PROG" >&2
        exit 127
    fi
    exec "$tool" "$@"
}

cmd_profile() {
    sub="${1:-current}"
    case "$sub" in
        current|show)
            if [ -r "$PROFILE_FILE" ]; then
                cat "$PROFILE_FILE"
            else
                # The profile system is not landed yet — see steps 5+ in
                # docs/FEATURE-REVIEW-AND-IDEAS.md. Default to server.
                printf 'server\n'
            fi
            ;;
        set)
            new="${2:-}"
            [ -n "$new" ] || { printf 'usage: %s profile set <name>\n' "$PROG" >&2; exit 2; }
            case "$new" in
                server|desktop) ;;
                *) printf 'error: unknown profile: %s (expected server|desktop)\n' "$new" >&2; exit 2 ;;
            esac
            mkdir -p "$(dirname "$PROFILE_FILE")"
            printf '%s\n' "$new" > "$PROFILE_FILE"
            printf 'profile set to %s (takes effect on next boot once profile overlays land)\n' "$new"
            ;;
        list)
            printf 'server\ndesktop\n'
            ;;
        *)
            printf 'usage: %s profile [current|set <name>|list]\n' "$PROG" >&2
            exit 2
            ;;
    esac
}

cmd_verify() {
    # Placeholder for the dm-verity verify path (step 9 in the review).
    # Today there is nothing to verify; print the current image identity so
    # the subcommand is at least useful as a status probe.
    if [ -r /etc/os-release ]; then
        . /etc/os-release 2>/dev/null || true
        printf 'image: %s %s\n' "${PRETTY_NAME:-qos}" "${VERSION_ID:-unknown}"
    fi
    if [ -r /etc/qos/build-version ]; then
        printf 'build: %s\n' "$(cat /etc/qos/build-version)"
    fi
    printf 'verity: not-configured (planned)\n'
    printf 'signing: not-configured (planned)\n'
}

cmd_version() {
    if [ -r /etc/qos/build-version ]; then
        cat /etc/qos/build-version
    else
        printf '%s (no build-version file)\n' "$PROG"
    fi
}

cmd_build() {
    # Host-side only. The repo root is wherever this script lives when run
    # from scripts/. Refuse to run on an installed system.
    if [ ! -f "$self_dir/../build.sh" ]; then
        printf 'error: qos build only works from inside the qos repo\n' >&2
        exit 2
    fi
    repo="$(CDPATH= cd -- "$self_dir/.." && pwd -P)"
    cd "$repo"
    exec make full "$@"
}

cmd_manifest() {
    gen="$self_dir/qos-manifest.sh"
    if [ ! -x "$gen" ]; then
        # Fall back to the .sh-less name when installed in /usr/bin.
        gen="$(find_tool qos-manifest || true)"
    fi
    if [ -z "$gen" ] || [ ! -x "$gen" ]; then
        printf 'error: qos-manifest helper not found\n' >&2
        exit 127
    fi
    exec "$gen" "$@"
}

main() {
    cmd="${1:-help}"
    [ "$#" -gt 0 ] && shift || true

    case "$cmd" in
        help|-h|--help|'') usage ;;
        version|--version) cmd_version ;;
        install)      run_tool qos-install "$@" ;;
        capability)   run_tool qos-capability "$@" ;;
        cluster)      run_tool qos-cluster "$@" ;;
        expand)       run_tool qos-expand "$@" ;;
        test)         run_tool qos-test "$@" ;;
        e2e)          run_tool qos-e2e-full "$@" ;;
        ota)          run_tool qos-ota "$@" ;;
        build)        cmd_build "$@" ;;
        manifest)     cmd_manifest "$@" ;;
        profile)      cmd_profile "$@" ;;
        verify)       cmd_verify "$@" ;;
        *)
            printf 'error: unknown command: %s\n\n' "$cmd" >&2
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
