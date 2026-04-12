#!/bin/sh
# qos-cluster - Cluster management CLI
# Usage: qos-cluster nodes
#        qos-cluster resources
#        qos-cluster status

set -e

CLUSTER_DATA="/var/lib/cluster"
MEMBERS_FILE="$CLUSTER_DATA/members.json"
STATUS_FILE="$CLUSTER_DATA/status.json"

usage() {
    cat <<EOF
Usage: qos-cluster <command>

Commands:
  nodes           List cluster members
  resources       Show cluster resource summary
  status          Show this node's status
  services        List available services in cluster
  help            Show this help message

Examples:
  qos-cluster nodes
  qos-cluster resources
  qos-cluster status
EOF
}

cmd_nodes() {
    echo "Cluster Members:"
    echo "================"
    
    # Show this node
    if [ -f "$STATUS_FILE" ]; then
        local node_id node_ip cpu_usage disk_usage
        node_id="$(grep -o '"node_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATUS_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
        node_ip="$(grep -o '"ip"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATUS_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
        cpu_usage="$(grep -o '"cpu_usage_percent"[[:space:]]*:[[:space:]]*[0-9.]*' "$STATUS_FILE" | head -1 | awk '{print $NF}')"
        disk_usage="$(grep -o '"disk_usage_percent"[[:space:]]*:[[:space:]]*[0-9]*' "$STATUS_FILE" | head -1 | awk '{print $NF}')"
        
        printf "  %-15s %-15s CPU: %5s%%  Disk: %3s%%  (this node)\n" \
            "$node_id" "$node_ip" "${cpu_usage:-0}" "${disk_usage:-0}"
    fi
    
    # Show other discovered nodes (if any)
    if [ -f "$MEMBERS_FILE" ]; then
        # In a real implementation, parse the members file
        echo "  (No other nodes discovered yet)"
    fi
    
    echo ""
    echo "Note: Cluster discovery is simplified in this version."
    echo "Full multicast support requires additional configuration."
}

cmd_resources() {
    echo "Cluster Resources:"
    echo "=================="
    
    if [ -f "$STATUS_FILE" ]; then
        local cpus ram_bytes cpu_usage disk_usage
        cpus="$(grep -o '"cpus"[[:space:]]*:[[:space:]]*[0-9]*' "$STATUS_FILE" | head -1 | awk '{print $NF}')"
        ram_bytes="$(grep -o '"ram_bytes"[[:space:]]*:[[:space:]]*[0-9]*' "$STATUS_FILE" | head -1 | awk '{print $NF}')"
        cpu_usage="$(grep -o '"cpu_usage_percent"[[:space:]]*:[[:space:]]*[0-9.]*' "$STATUS_FILE" | head -1 | awk '{print $NF}')"
        disk_usage="$(grep -o '"disk_usage_percent"[[:space:]]*:[[:space:]]*[0-9]*' "$STATUS_FILE" | head -1 | awk '{print $NF}')"
        
        local ram_mb=$(( ${ram_bytes:-0} / 1024 / 1024 ))
        
        echo "  This Node:"
        printf "    CPUs:      %s\n" "${cpus:-0}"
        printf "    RAM:       %s MB\n" "$ram_mb"
        printf "    CPU Usage: %s%%\n" "${cpu_usage:-0}"
        printf "    Disk Usage: %s%%\n" "${disk_usage:-0}"
        echo ""
        echo "Note: Multi-node resource aggregation requires cluster membership."
    else
        echo "  No status information available yet."
        echo "  Wait for cluster daemon to initialize."
    fi
}

cmd_status() {
    echo "Node Status:"
    echo "============"
    
    if [ -f "$STATUS_FILE" ]; then
        cat "$STATUS_FILE"
    else
        echo "  Status file not found. Is cluster daemon running?"
        return 1
    fi
}

cmd_services() {
    echo "Cluster Services:"
    echo "================="
    
    # List s6 services
    echo "  Local Services:"
    if [ -d /run/service ]; then
        for svc in /run/service/*; do
            [ -e "$svc" ] || continue
            local name
            name="$(basename "$svc")"
            echo "    - $name"
        done
    fi
}

# Main command dispatcher
case "${1:-help}" in
    nodes)
        cmd_nodes
        ;;
    resources)
        cmd_resources
        ;;
    status)
        cmd_status
        ;;
    services)
        cmd_services
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
