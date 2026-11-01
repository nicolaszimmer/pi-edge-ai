#!/usr/bin/env bash
# Health report: service, models, temperature, throttling, memory.
#   ./status.sh
set -uo pipefail

URL="${LLM_URL:-http://127.0.0.1:8080}"
KEY="${LLM_API_KEY:-}"
if [[ -z "$KEY" && -f /etc/pi-llm/api-keys ]]; then
    KEY=$(sudo grep -v '^#' /etc/pi-llm/api-keys | head -1)
fi

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }

bold "Service"
systemctl is-active pi-llm || true
systemctl show pi-llm -p ActiveEnterTimestamp --value 2>/dev/null | sed 's/^/  since /'

bold "Models"
curl -fsS -H "Authorization: Bearer $KEY" "$URL/v1/models" 2>/dev/null \
    | jq -r '.data[] | "  \(.id): \(.status.value // "loaded")"' \
    || echo "  API not reachable at $URL"

if command -v vcgencmd >/dev/null; then
    bold "Board"
    echo "  $(vcgencmd measure_temp)   CPU clock: $(( $(vcgencmd measure_clock arm | cut -d= -f2) / 1000000 )) MHz"
    echo "  CPU governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    t=$(vcgencmd get_throttled | cut -d= -f2)
    if (( t == 0 )); then
        echo "  Throttling: none (good)"
    else
        echo "  Throttling flags: $t"
        (( t & 0x1 ))     && echo "    ! under-voltage NOW: use the official 27 W (5 V / 5 A) power supply"
        (( t & 0x2 ))     && echo "    ! CPU frequency capped NOW"
        (( t & 0x4 ))     && echo "    ! throttled NOW"
        (( t & 0x8 ))     && echo "    ! soft temperature limit NOW: improve cooling (Active Cooler)"
        (( t & 0x10000 )) && echo "    - under-voltage happened since boot"
        (( t & 0x20000 )) && echo "    - frequency capping happened since boot"
        (( t & 0x40000 )) && echo "    - throttling happened since boot"
        (( t & 0x80000 )) && echo "    - soft temperature limit happened since boot"
    fi
fi

bold "Memory"
free -h | sed 's/^/  /'

bold "Disk"
df -h / /opt/pi-llm 2>/dev/null | awk 'NR == 1 || !seen[$1]++' | sed 's/^/  /'
