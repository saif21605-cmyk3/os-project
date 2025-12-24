#!/usr/bin/env bash
# monitor.sh - FULL FIXED (single file), TA-friendly JSON, WSL-safe sampling
# + Host->WSL forwarding (Windows writes host_metrics.json) with BOM-safe reader
# + Alert system (CPU/RAM/Disk) + alerts log
# Outputs:
#   out/metrics.json   (latest snapshot)
#   out/metrics.jsonl  (history, JSONL)
#   out/alerts.log     (alerts history)

set -euo pipefail

OUTPUT_DIR="${OUTPUT_PATH:-out}"
LATEST_FILE="${OUTPUT_DIR}/metrics.json"
HISTORY_FILE="${OUTPUT_DIR}/metrics.jsonl"

INTERVAL=3
COUNT=0                 # 0 = infinite
CPU_SAMPLE_DELAY=1      # recommended 0.5–1s for stable CPU %

mkdir -p "$OUTPUT_DIR"

########################
# Alert thresholds
########################
CPU_ALERT_PCT=90
RAM_ALERT_PCT=85
DISK_ALERT_PCT=90

ALERT_LOG="${OUTPUT_DIR}/alerts.log"

########################
# Helpers
########################
json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  echo "$s"
}

alerts_to_json() {
  local out="["
  local first=1
  local a
  for a in "$@"; do
    if (( first )); then
      first=0
    else
      out+=","
    fi
    out+="\"$(json_escape "$a")\""
  done
  out+="]"
  echo "$out"
}

is_wsl() {
  grep -qi "microsoft" /proc/sys/kernel/osrelease 2>/dev/null
}

normalize_na() {
  local s="${1:-}"
  s="${s//\[/}"
  s="${s//\]/}"
  s="$(echo "$s" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -z "$s" ]] && echo "N/A" || echo "$s"
}

is_number() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# JSON value helpers
num_or_null() {
  local v
  v="$(normalize_na "${1:-}")"
  if is_number "$v"; then echo "$v"; else echo "null"; fi
}

str_or_null() {
  local v
  v="$(normalize_na "${1:-}")"
  if [[ "$v" == "N/A" || "$v" == "unavailable" ]]; then
    echo "null"
  else
    echo "\"$(json_escape "$v")\""
  fi
}

########################
# Host->WSL forwarding (Windows writes this file)
########################
HOST_METRICS_FILE="${HOST_METRICS_PATH:-/mnt/c/Users/adham/system-monitor/out/host_metrics.json}"

# BOM-safe JSON reader: use utf-8-sig
host_json_get() {
  local key="$1"
  [[ -f "$HOST_METRICS_FILE" ]] || { echo "N/A"; return; }
  python3 - "$HOST_METRICS_FILE" "$key" <<'PY'
import json, sys
p=sys.argv[1]
k=sys.argv[2]
try:
    with open(p,"r",encoding="utf-8-sig") as f:
        d=json.load(f)
    v=d.get(k,None)
    print("N/A" if v is None else v)
except Exception:
    print("N/A")
PY
}

# Your host JSON has disks_host as a *single object*:
# "disks_host": { "FriendlyName": "...", "HealthStatus": "Healthy" }
get_host_disk_health() {
  [[ -f "$HOST_METRICS_FILE" ]] || { echo "N/A"; return; }
  python3 - "$HOST_METRICS_FILE" <<'PY'
import json, sys
p=sys.argv[1]
try:
    with open(p,"r",encoding="utf-8-sig") as f:
        d=json.load(f)
    disks=d.get("disks_host")
    if isinstance(disks, dict):
        name=disks.get("FriendlyName","Disk")
        hs=disks.get("HealthStatus","Unknown")
        print(f"{name}={hs}")
    elif isinstance(disks, list):
        parts=[]
        for x in disks:
            name=x.get("FriendlyName","Disk")
            hs=x.get("HealthStatus","Unknown")
            parts.append(f"{name}={hs}")
        print(";".join(parts) if parts else "N/A")
    else:
        print("N/A")
except Exception:
    print("N/A")
PY
}

########################
# CPU
########################
get_cpu_cores() {
  command -v nproc >/dev/null 2>&1 && nproc || (grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)
}

get_cpu_model() {
  local m
  m="$(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  [[ -n "${m:-}" ]] && echo "$m" || echo "N/A"
}

get_cpu_freq_ghz() {
  local mhz
  mhz="$(awk -F: '/cpu MHz/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  if [[ -n "${mhz:-}" ]]; then
    awk -v mhz="$mhz" 'BEGIN {printf "%.2f", mhz/1000}'
    return
  fi
  if command -v lscpu >/dev/null 2>&1; then
    mhz="$(lscpu 2>/dev/null | awk -F: '/CPU MHz/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
    [[ -n "${mhz:-}" ]] && awk -v mhz="$mhz" 'BEGIN {printf "%.2f", mhz/1000}' && return
  fi
  echo "N/A"
}

_cpu_read_totals() {
  # prints: idle_all total
  awk '
    /^cpu /{
      idle_all = $5 + $6;            # idle + iowait
      total = 0;
      for(i=2;i<=NF;i++) total += $i; # sum all fields except label
      print idle_all, total;
      exit
    }' /proc/stat
}

get_cpu_usage_percent() {
  local idle1 total1 idle2 total2 diff_idle diff_total
  read -r idle1 total1 < <(_cpu_read_totals)
  sleep "$CPU_SAMPLE_DELAY"
  read -r idle2 total2 < <(_cpu_read_totals)

  diff_idle=$(( idle2 - idle1 ))
  diff_total=$(( total2 - total1 ))

  if (( diff_total <= 0 )); then
    echo "0.0"
    return
  fi

  awk -v di="$diff_idle" -v dt="$diff_total" 'BEGIN {printf "%.1f", 100*(1 - (di/dt))}'
}

get_cpu_temp() {
  # 1. Try host file (works for WSL and Docker)
  local host_temp
  host_temp="$(host_json_get cpu_temp_c_host)"
  if is_number "$(normalize_na "$host_temp")"; then
    echo "$host_temp"
    return
  fi

  # 2. Try lm-sensors (Linux native)
  if command -v sensors >/dev/null 2>&1; then
    local line
    line="$(sensors 2>/dev/null | sed -n 's/.*[Pp]ackage id 0: *+*\([0-9.]\+\)°C.*/\1/p' | head -n1 || true)"
    [[ -n "${line:-}" ]] && echo "$line" && return
  fi

  # 3. Try sysfs thermal zones
  local tf val
  for tf in /sys/class/thermal/thermal_zone*/temp; do
    if [[ -f "$tf" ]]; then
      val="$(cat "$tf" 2>/dev/null || true)"
      if [[ -n "${val:-}" ]] && [[ "$val" =~ ^[0-9]+$ ]] && (( val > 0 )); then
        echo "$val" | awk '{printf "%.1f", $1/1000}'
        return
      fi
    fi
  done

  echo "N/A"
}

########################
# GPU (NVIDIA) - safe, no crashes
########################
# returns: util,temp,power,fan,pstate,thermal,pcap,hwslow
get_gpu_info() {
  # 1. Try local nvidia-smi
  if command -v nvidia-smi >/dev/null 2>&1; then
    local line=""
    set +e
    line="$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw,fan.speed,pstate,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_power_cap,clocks_throttle_reasons.hw_slowdown \
          --format=csv,noheader,nounits 2>/dev/null | head -n1)"
    local rc=$?
    set -e

    if [[ $rc -eq 0 && -n "${line:-}" ]]; then
      echo "$line" | sed 's/, */,/g'
      return
    fi
  fi

  # 2. Try host file (Docker/WSL)
  if [[ -f "$HOST_METRICS_FILE" ]]; then
     python3 - "$HOST_METRICS_FILE" <<'PY' | grep -v "FAIL" && return || true
import json, sys
p=sys.argv[1]
try:
    with open(p,"r",encoding="utf-8-sig") as f: d=json.load(f)
    g=d.get("gpu_host")
    if g and isinstance(g, dict):
        # utilization.gpu,temperature.gpu,power.draw,fan.speed,pstate,thermal,powercap,hwslow
        u=g.get("utilization.gpu","N/A")
        t=g.get("temperature.gpu","N/A")
        p=g.get("power.draw","N/A")
        f=g.get("fan.speed","N/A")
        ps=g.get("pstate","N/A")
        th=g.get("thermal","unavailable")
        pc=g.get("powercap","unavailable")
        hw=g.get("hwslow","unavailable")
        print(f"{u},{t},{p},{f},{ps},{th},{pc},{hw}")
    else:
        print("FAIL")
except:
    print("FAIL")
PY
  fi

  echo "N/A,N/A,N/A,N/A,N/A,unavailable,unavailable,unavailable"
}

gpu_health_from_reasons() {
  local thermal="$1" pcap="$2" hwslow="$3"
  if [[ "$thermal" == "unavailable" ]]; then
    echo "unavailable"
  elif [[ "$thermal" == "Active" ]]; then
    echo "THERMAL THROTTLING"
  elif [[ "$hwslow" == "Active" ]]; then
    echo "HW SLOWDOWN"
  elif [[ "$pcap" == "Active" ]]; then
    echo "POWER LIMITED"
  else
    echo "OK"
  fi
}

########################
# Disk
########################
get_all_disks_json() {
  df -P -hT 2>/dev/null \
  | awk '
      NR==1 {next}
      {
        fs=$1; type=$2; size=$3; used=$4; avail=$5; pct=$6; mount=$7;

        # exclude pseudo fs types
        if (type ~ /^(tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|cgroup|cgroup2|securityfs|pstore|debugfs|tracefs|autofs|mqueue|hugetlbfs|ramfs|nsfs)$/) next;

        # exclude noisy WSL mounts by path
        if (mount ~ /^\/(run|init)(\/|$)/) next;
        if (mount ~ /^\/usr\/lib\/(wsl|modules)/) next;
        if (mount ~ /^\/mnt\/(wsl|wslg)(\/|$)/) next;

        # keep common "real" types
        if (!(type ~ /^(ext[234]|xfs|btrfs|fuseblk|drvfs|vfat|ntfs3|ntfs)$/)) next;

        gsub(/"/,"",fs); gsub(/"/,"",mount); gsub(/"/,"",type);

        printf "{\"filesystem\":\"%s\",\"type\":\"%s\",\"mount\":\"%s\",\"size\":\"%s\",\"used\":\"%s\",\"avail\":\"%s\",\"used_percent\":\"%s\"}\n",
               fs,type,mount,size,used,avail,pct
      }' \
  | awk 'BEGIN{print "["} {print (NR==1? "" : ",") $0} END{print "]"}'
}

detect_root_disk() {
  local src dev
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ "$src" == /dev/* ]] || { echo ""; return; }
  dev="$src"
  dev="${dev%p[0-9]*}"  # nvme partitions
  dev="${dev%[0-9]*}"   # sata partitions
  [[ -b "$dev" ]] && echo "$dev" || echo ""
}

get_smart_health() {
  if is_wsl; then
    echo "N/A"
    return
  fi
  if ! command -v smartctl >/dev/null 2>&1; then
    echo "smartctl not installed"
    return
  fi

  local dev
  dev="$(detect_root_disk)"
  [[ -z "${dev:-}" ]] && { echo "disk device not found"; return; }

  local health
  health="$(
    sudo -n smartctl -H "$dev" 2>/dev/null | awk -F: '
      /SMART overall-health self-assessment test result/ {gsub(/^[ \t]+/, "", $2); print $2; exit}
      /SMART Health Status/ {gsub(/^[ \t]+/, "", $2); print $2; exit}
    ' || true
  )"
  [[ -n "${health:-}" ]] && echo "$health" || echo "SMART unavailable (needs sudo?)"
}

########################
# Network + rate (bytes/sec)
########################
get_net_iface() {
  awk -F: 'NR>2 {gsub(" ","",$1); if ($1!="lo") {print $1; exit}}' /proc/net/dev
}

get_net_stats() {
  local iface="${1:-}"
  [[ -z "$iface" ]] && { echo "N/A,N/A"; return; }
  awk -v iface="$iface" '
    $1 ~ iface":" {
      gsub(":", "", $1);
      rx=$2; tx=$10;
      print rx","tx;
      exit
    }
  ' /proc/net/dev
}

# Persist previous rx/tx/time for rate
PREV_NET_TS=0
PREV_NET_RX=0
PREV_NET_TX=0

calc_rate() {
  local now_ts="$1" cur_rx="$2" cur_tx="$3"
  if (( PREV_NET_TS == 0 )); then
    PREV_NET_TS="$now_ts"
    PREV_NET_RX="$cur_rx"
    PREV_NET_TX="$cur_tx"
    echo "0 0"
    return
  fi

  local dt=$(( now_ts - PREV_NET_TS ))
  if (( dt <= 0 )); then dt=1; fi

  local drx=$(( cur_rx - PREV_NET_RX ))
  local dtx=$(( cur_tx - PREV_NET_TX ))
  if (( drx < 0 )); then drx=0; fi
  if (( dtx < 0 )); then dtx=0; fi

  PREV_NET_TS="$now_ts"
  PREV_NET_RX="$cur_rx"
  PREV_NET_TX="$cur_tx"

  # integer bytes/sec
  echo $(( drx / dt )) $(( dtx / dt ))
}

########################
# Args
########################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="${2:-3}"; shift 2 ;;
    --count) COUNT="${2:-0}"; shift 2 ;;
    --cpu-sample) CPU_SAMPLE_DELAY="${2:-1}"; shift 2 ;;
    *) shift ;;
  esac
done

########################
# Main loop
########################
n=0
while true; do
  TIMESTAMP="$(date +"%Y-%m-%d %H:%M:%S")"
  NOW_TS="$(date +%s)"
  LOAD_AVG="$(awk '{print $1","$2","$3}' /proc/loadavg)"

  MEM_TOTAL="$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)"
  MEM_AVAILABLE="$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo)"
  MEM_USED="$((MEM_TOTAL - MEM_AVAILABLE))"

  # CPU
  CPU_USAGE="$(get_cpu_usage_percent)"
  CPU_TEMP="$(get_cpu_temp)"
  CPU_CORES="$(get_cpu_cores)"
  CPU_MODEL="$(get_cpu_model)"
  CPU_FREQ_GHZ="$(get_cpu_freq_ghz)"

  # If running WSL: try host temp (only works if host provides a number)
  if is_wsl; then
    CPU_TEMP_HOST="$(host_json_get cpu_temp_c_host)"
    if is_number "$(normalize_na "$CPU_TEMP_HOST")"; then
      CPU_TEMP="$CPU_TEMP_HOST"
    fi
  fi

  # GPU
  GPU_INFO="$(get_gpu_info)"
  GPU_UTIL="$(echo "$GPU_INFO" | cut -d',' -f1)"
  GPU_TEMP_VAL="$(echo "$GPU_INFO" | cut -d',' -f2)"
  GPU_POWER_W="$(echo "$GPU_INFO" | cut -d',' -f3)"
  GPU_FAN_PCT="$(echo "$GPU_INFO" | cut -d',' -f4)"
  GPU_PSTATE="$(echo "$GPU_INFO" | cut -d',' -f5)"
  GPU_THERMAL="$(normalize_na "$(echo "$GPU_INFO" | cut -d',' -f6)")"
  GPU_PCAP="$(normalize_na "$(echo "$GPU_INFO" | cut -d',' -f7)")"
  GPU_HWSLOW="$(normalize_na "$(echo "$GPU_INFO" | cut -d',' -f8)")"
  GPU_HEALTH="$(gpu_health_from_reasons "$GPU_THERMAL" "$GPU_PCAP" "$GPU_HWSLOW")"

  # GPU Name (try local first, then host)
  GPU_NAME=""
  if command -v nvidia-smi >/dev/null 2>&1; then
      GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo "")"
  fi
  if [[ -z "$GPU_NAME" || "$GPU_NAME" == "N/A" ]] && [[ -f "$HOST_METRICS_FILE" ]]; then
     GPU_NAME="$(host_json_get gpu_name_host)"
  fi

  # Disks
  DISKS_JSON="$(get_all_disks_json)"
  DISK_USED_ROOT="$(df -h / 2>/dev/null | awk 'NR==2 {print $3}' || echo "N/A")"
  DISK_TOTAL_ROOT="$(df -h / 2>/dev/null | awk 'NR==2 {print $2}' || echo "N/A")"
  DISK_PERCENT_ROOT="$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' || echo "N/A")"
  DISK_SMART="$(get_smart_health)"

  # Alerts (CPU/RAM/DISK + optional GPU thermal)
  ALERTS=()

  CPU_INT="${CPU_USAGE%.*}"
  if [[ "$CPU_INT" =~ ^[0-9]+$ ]] && (( CPU_INT > CPU_ALERT_PCT )); then
    ALERTS+=("HIGH CPU USAGE: ${CPU_USAGE}% (>${CPU_ALERT_PCT}%)")
  fi

  RAM_PCT=0
  if [[ "$MEM_TOTAL" =~ ^[0-9]+$ ]] && (( MEM_TOTAL > 0 )); then
    RAM_PCT=$(( (MEM_USED * 100) / MEM_TOTAL ))
    if (( RAM_PCT > RAM_ALERT_PCT )); then
      ALERTS+=("HIGH MEMORY USAGE: ${RAM_PCT}% (>${RAM_ALERT_PCT}%)")
    fi
  fi

  DISK_PCT_NUM="$(echo "$DISK_PERCENT_ROOT" | tr -d '%' | tr -d ' ')"
  DISK_PCT_NUM="${DISK_PCT_NUM:-0}"
  if [[ "$DISK_PCT_NUM" =~ ^[0-9]+$ ]] && (( DISK_PCT_NUM > DISK_ALERT_PCT )); then
    ALERTS+=("DISK USAGE CRITICAL: ${DISK_PERCENT_ROOT} (>${DISK_ALERT_PCT}%)")
  fi

  if [[ "$(echo "$GPU_HEALTH" | tr '[:lower:]' '[:upper:]')" == *"THERMAL"* ]]; then
    ALERTS+=("GPU THERMAL THROTTLING DETECTED")
  fi

  if (( ${#ALERTS[@]} > 0 )); then
    for a in "${ALERTS[@]}"; do
      echo "[$TIMESTAMP] $a" >> "$ALERT_LOG"
    done
  fi

  ALERTS_JSON="$(alerts_to_json "${ALERTS[@]}")"
  ALERTS_COUNT="${#ALERTS[@]}"

  # If WSL: replace disk health with host disk health (friendly)
  if is_wsl; then
    HOST_DISK_HEALTH="$(get_host_disk_health)"
    if [[ "$(normalize_na "$HOST_DISK_HEALTH")" != "N/A" ]]; then
      DISK_SMART="$HOST_DISK_HEALTH"
    fi
  fi

  # Network
  NET_IFACE="$(get_net_iface)"
  NET_STATS="$(get_net_stats "$NET_IFACE")"
  NET_RX_BYTES="$(echo "$NET_STATS" | cut -d',' -f1)"
  NET_TX_BYTES="$(echo "$NET_STATS" | cut -d',' -f2)"

  # Rates (bytes/sec)
  RX_RATE=0
  TX_RATE=0
  if is_number "$NET_RX_BYTES" && is_number "$NET_TX_BYTES"; then
    read -r RX_RATE TX_RATE < <(calc_rate "$NOW_TS" "$NET_RX_BYTES" "$NET_TX_BYTES")
  fi

  UPTIME="$(uptime -p 2>/dev/null || echo "N/A")"

  JSON="$(cat <<EOF
{
  "timestamp": "$(json_escape "$TIMESTAMP")",

  "cpu_load_1m": "$(echo "$LOAD_AVG" | cut -d',' -f1)",
  "cpu_load_5m": "$(echo "$LOAD_AVG" | cut -d',' -f2)",
  "cpu_load_15m": "$(echo "$LOAD_AVG" | cut -d',' -f3)",

  "cpu_usage_percent": $CPU_USAGE,
  "cpu_temp_c": $(str_or_null "$CPU_TEMP"),
  "cpu_cores": $CPU_CORES,
  "cpu_model": "$(json_escape "$CPU_MODEL")",
  "cpu_freq_ghz": $(str_or_null "$CPU_FREQ_GHZ"),

  "gpu_util_percent": $(num_or_null "$GPU_UTIL"),
  "gpu_temp_c": $(num_or_null "$GPU_TEMP_VAL"),
  "gpu_power_w": $(num_or_null "$GPU_POWER_W"),
  "gpu_fan_percent": $(num_or_null "$GPU_FAN_PCT"),
  "gpu_pstate": $(str_or_null "$GPU_PSTATE"),
  "gpu_throttle_thermal": $(str_or_null "$GPU_THERMAL"),
  "gpu_throttle_power_cap": $(str_or_null "$GPU_PCAP"),
  "gpu_throttle_hw_slowdown": $(str_or_null "$GPU_HWSLOW"),
  "gpu_health": "$(json_escape "$GPU_HEALTH")",
  "gpu_name": $(str_or_null "$GPU_NAME"),

  "mem_total_mb": $MEM_TOTAL,
  "mem_used_mb": $MEM_USED,
  "mem_available_mb": $MEM_AVAILABLE,
  "mem_used_percent": $RAM_PCT,

  "disk_root_used": "$(json_escape "$DISK_USED_ROOT")",
  "disk_root_total": "$(json_escape "$DISK_TOTAL_ROOT")",
  "disk_root_used_percent": "$(json_escape "$DISK_PERCENT_ROOT")",
  "disk_root_used_percent_num": $DISK_PCT_NUM,
  "disk_smart_health": $(str_or_null "$DISK_SMART"),

  "disks": $DISKS_JSON,

  "net_iface": "$(json_escape "$NET_IFACE")",
  "net_rx_bytes": $(num_or_null "$NET_RX_BYTES"),
  "net_tx_bytes": $(num_or_null "$NET_TX_BYTES"),
  "net_rx_bytes_per_sec": $RX_RATE,
  "net_tx_bytes_per_sec": $TX_RATE,

  "alerts": $ALERTS_JSON,
  "alerts_count": $ALERTS_COUNT,

  "uptime": "$(json_escape "$UPTIME")"
}
EOF
)"

  # write pretty snapshot
echo "$JSON" > "$LATEST_FILE"

# write compact JSONL line (1 record = 1 line)
COMPACT="$(python3 -c 'import json,sys; s=sys.stdin.read().strip(); 
import sys as _s; 
print(json.dumps(json.loads(s), separators=(",",":"), ensure_ascii=False))' <<< "$JSON")"


echo "$COMPACT" >> "$HISTORY_FILE"

  echo "Updated: $LATEST_FILE (history appended to $HISTORY_FILE)"

  n=$((n+1))
  if (( COUNT > 0 && n >= COUNT )); then
    echo "Done. Collected $n records."
    break
  fi

  sleep "$INTERVAL"
done
