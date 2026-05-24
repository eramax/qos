#!/bin/sh


# Only print for interactive shells unless a test explicitly forces it.
case "$-" in
  *i*) ;;
  *) [ "${QOS_BANNER_FORCE:-0}" = "1" ] || return 0 || exit 0 ;;
esac

qos_root="${QOS_ROOTFS:-/}"
version_file="${QOS_VERSION_FILE:-$qos_root/etc/qos/version}"
meminfo_file="${QOS_MEMINFO_FILE:-$qos_root/proc/meminfo}"
uptime_file="${QOS_UPTIME_FILE:-$qos_root/proc/uptime}"
boot_source_file="${QOS_BOOT_SOURCE_FILE:-$qos_root/etc/qos/boot-source}"
df_path="${QOS_DF_PATH:-/}"
ip_bin="${QOS_IP_BIN:-ip}"

qos_version="QOS build: unknown"
if [ -r "$version_file" ]; then
  qos_version="$(cat "$version_file" || printf '%s' "$qos_version")"
fi

kernel_version="$(uname -r || printf 'unknown')"
mem_kib="$(awk '/^MemTotal:/ { print $2; exit }' "$meminfo_file" || printf '0')"
case "$mem_kib" in
  ''|*[!0-9]*) mem_kib=0 ;;
esac
ram_mib=$(( (mem_kib + 1023) / 1024 ))

uptime_minutes="$(awk '{
  s = int($1)
  d = int(s / 86400)
  h = int((s % 86400) / 3600)
  m = int((s % 3600) / 60)
  if (d > 0) {
    printf "%dd %dh %dm", d, h, m
  } else if (h > 0) {
    printf "%dh %dm", h, m
  } else {
    printf "%dm", m
  }
}' "$uptime_file" || printf 'unknown')"

ipv4_addr="$("$ip_bin" -o -4 addr show scope global | awk '
  {
    for (i = 1; i <= NF; i++) {
      if ($i == "inet") {
        print $(i + 1)
        exit
      }
    }
  }
')"
[ -n "$ipv4_addr" ] || ipv4_addr="none"

ipv6_addr="$("$ip_bin" -o -6 addr show scope global | awk '
  {
    for (i = 1; i <= NF; i++) {
      if ($i == "inet6") {
        print $(i + 1)
        exit
      }
    }
  }
')"
[ -n "$ipv6_addr" ] || ipv6_addr="none"

disk_line="$(df -h "$df_path" | awk 'NR==2 { printf "%s total, %s used, %s free (%s used)", $2, $3, $4, $5 }')"
[ -n "$disk_line" ] || disk_line="unknown"

boot_source="$(cat "$boot_source_file" || true)"

printf '\n'
cat <<'EOF'
 .d88888b.   .d88888b.   .d8888b.  
d88P" "Y88b d88P" "Y88b d88P  Y88b 
888     888 888     888 Y88b.      
888     888 888     888  "Y888b.   
888     888 888     888     "Y88b. 
888 Y8b 888 888     888       "888 
Y88b.Y8b88P Y88b. .d88P Y88b  d88P 
 "Y888888"   "Y88888P"   "Y8888P"  
       Y8b                                                                              
EOF
boot_time_sec=""
if [ -r /run/qos-boot-start ]; then
  boot_start="$(cat /run/qos-boot-start)"
  now="$(awk '{print $1}' /proc/uptime)"
  boot_sec="$(awk -v s="$boot_start" -v n="$now" 'BEGIN { printf "%.1f", n - s }')"
  boot_time_sec=" (boot: ${boot_sec}s)"
fi

printf '%s\n' '========================================'
printf '%s\n' "$qos_version"
if [ "$boot_source" = "live-cdrom" ]; then
  printf '%s\n' "Boot: live CD-ROM"
fi
printf '%s\n' "Kernel: $kernel_version"
printf '%s\n' "Uptime: $uptime_minutes$boot_time_sec"
printf '%s\n' "IPv4: $ipv4_addr"
printf '%s\n' "IPv6: $ipv6_addr"
printf '%s\n' "RAM: ${ram_mib} MiB"
printf '%s\n' "Disk: $disk_line"
printf '%s\n' '========================================'
printf '\n'
