#!/bin/sh
# qos-capability - Apply capability profiles to services
# Usage: qos-capability apply <service> <profile.cap>
#        qos-capability show <service>
#        qos-capability list

set -e

CAPABILITIES_DIR="/etc/qos/capabilities/profiles"
CGROUP_BASE="/sys/fs/cgroup"

usage() {
    cat <<EOF
Usage: qos-capability <command> [options]

Commands:
  apply <service> <profile>   Apply capability profile to service
  show <service>              Show current capability settings
  list                        List available capability profiles
  test <service>              Test capability enforcement
  help                        Show this help message

Examples:
  qos-capability apply webapp webapp.cap
  qos-capability apply reverse-proxy reverse-proxy.cap
  qos-capability show webapp
  qos-capability list
EOF
}

cmd_list() {
    echo "Available capability profiles:"
    if [ -d "$CAPABILITIES_DIR" ]; then
        for cap_file in "$CAPABILITIES_DIR"/*.cap; do
            [ -f "$cap_file" ] || continue
            name="$(basename "$cap_file" .cap)"
            desc="$(grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' "$cap_file" | head -1 | sed 's/.*"description"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')"
            printf "  %-20s %s\n" "$name" "$desc"
        done
    fi
}

cmd_show() {
    local service="$1"
    local cgroup_path="$CGROUP_BASE/$service"
    
    if [ ! -d "$cgroup_path" ]; then
        echo "Service '$service' not found in cgroups"
        return 1
    fi
    
    echo "Capability settings for service: $service"
    echo "========================================="
    
    if [ -f "$cgroup_path/cpu.max" ]; then
        echo "CPU:    $(cat "$cgroup_path/cpu.max")"
    fi
    
    if [ -f "$cgroup_path/memory.max" ]; then
        echo "Memory: $(cat "$cgroup_path/memory.max")"
    fi
    
    if [ -f "$cgroup_path/pids.max" ]; then
        echo "PIDs:   $(cat "$cgroup_path/pids.max")"
    fi
    
    if [ -f "$cgroup_path/io.max" ]; then
        echo "I/O:    $(cat "$cgroup_path/io.max")"
    fi
}

cmd_apply() {
    local service="$1"
    local profile="$2"
    local cap_file="$CAPABILITIES_DIR/$profile"
    
    if [ ! -f "$cap_file" ]; then
        echo "Error: Profile file not found: $cap_file"
        return 1
    fi
    
    # Parse capability file (simple JSON parsing with grep/sed)
    local cpu_quota memory_max pids_max
    
    cpu_quota="$(grep -o '"quota_percent"[[:space:]]*:[[:space:]]*[0-9]*' "$cap_file" | head -1 | grep -o '[0-9]*$')"
    memory_max="$(grep -o '"max_bytes"[[:space:]]*:[[:space:]]*"[^"]*"' "$cap_file" | head -1 | sed 's/.*"\([0-9]*[A-Z]*\)"/\1/')"
    pids_max="$(grep -o '"max"[[:space:]]*:[[:space:]]*[0-9]*' "$cap_file" | head -1 | grep -o '[0-9]*$')"
    
    # Create cgroup for service
    local cgroup_path="$CGROUP_BASE/$service"
    mkdir -p "$cgroup_path" 2>/dev/null || true
    
    # Apply CPU quota
    if [ -n "$cpu_quota" ] && [ -f "$cgroup_path/cpu.max" ]; then
        local period=100000
        local quota=$((cpu_quota * period / 100))
        echo "$quota $period" > "$cgroup_path/cpu.max" 2>/dev/null || {
            echo "Warning: Could not set CPU quota for $service"
        }
    fi
    
    # Apply memory limit
    if [ -n "$memory_max" ] && [ -f "$cgroup_path/memory.max" ]; then
        # Convert to bytes
        local mem_bytes
        case "$memory_max" in
            *G) mem_bytes=$(( ${memory_max%G} * 1024 * 1024 * 1024 )) ;;
            *M) mem_bytes=$(( ${memory_max%M} * 1024 * 1024 )) ;;
            *K) mem_bytes=$(( ${memory_max%K} * 1024 )) ;;
            *)  mem_bytes="$memory_max" ;;
        esac
        echo "$mem_bytes" > "$cgroup_path/memory.max" 2>/dev/null || {
            echo "Warning: Could not set memory limit for $service"
        }
    fi
    
    # Apply PID limit
    if [ -n "$pids_max" ] && [ -f "$cgroup_path/pids.max" ]; then
        echo "$pids_max" > "$cgroup_path/pids.max" 2>/dev/null || {
            echo "Warning: Could not set PID limit for $service"
        }
    fi
    
    echo "Applied capability profile '$profile' to service '$service'"
}

cmd_test() {
    local service="$1"
    local cgroup_path="$CGROUP_BASE/$service"
    
    if [ ! -d "$cgroup_path" ]; then
        echo "Service '$service' not found"
        return 1
    fi
    
    echo "Testing capability enforcement for: $service"
    echo "============================================"
    
    # Test CPU limit
    if [ -f "$cgroup_path/cpu.max" ]; then
        local cpu_val
        cpu_val="$(cat "$cgroup_path/cpu.max")"
        if [ "$cpu_val" != "max 100000" ]; then
            echo "✓ CPU quota enforced: $cpu_val"
        else
            echo "✗ CPU quota not set"
        fi
    fi
    
    # Test memory limit
    if [ -f "$cgroup_path/memory.max" ]; then
        local mem_val
        mem_val="$(cat "$cgroup_path/memory.max")"
        if [ "$mem_val" != "max" ]; then
            echo "✓ Memory limit enforced: $mem_val"
        else
            echo "✗ Memory limit not set"
        fi
    fi
    
    # Test PID limit
    if [ -f "$cgroup_path/pids.max" ]; then
        local pids_val
        pids_val="$(cat "$cgroup_path/pids.max")"
        if [ "$pids_val" != "max" ]; then
            echo "✓ PID limit enforced: $pids_val"
        else
            echo "✗ PID limit not set"
        fi
    fi
}

# Main command dispatcher
case "${1:-help}" in
    apply)
        [ -n "${2:-}" ] || { echo "Error: service name required"; exit 1; }
        [ -n "${3:-}" ] || { echo "Error: profile name required"; exit 1; }
        cmd_apply "$2" "$3"
        ;;
    show)
        [ -n "${2:-}" ] || { echo "Error: service name required"; exit 1; }
        cmd_show "$2"
        ;;
    list)
        cmd_list
        ;;
    test)
        [ -n "${2:-}" ] || { echo "Error: service name required"; exit 1; }
        cmd_test "$2"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac
