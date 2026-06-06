#!/usr/bin/env bash
# Waybar GPU module for the RTX 4060 Ti via nvidia-smi
icon=$'\uf2db'   # nerd-font chip glyph

data=$(nvidia-smi \
  --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw \
  --format=csv,noheader,nounits 2>/dev/null)

if [ -z "$data" ]; then
  printf '{"text":"%s n/a","tooltip":"nvidia-smi unavailable","class":"gpu"}\n' "$icon"
  exit 0
fi

util=$(echo "$data"  | awk -F', *' '{print $1}')
temp=$(echo "$data"  | awk -F', *' '{print $2}')
mused=$(echo "$data" | awk -F', *' '{print $3}')
mtot=$(echo "$data"  | awk -F', *' '{print $4}')
power=$(echo "$data" | awk -F', *' '{printf "%.0f", $5}')

# color the bar text by load
cls="gpu"
[ "${util:-0}" -ge 80 ] && cls="gpu-hot"

printf '{"text":"%s %s%%","tooltip":"GPU   %s%%    %s°C\\nVRAM  %s / %s MiB\\nPower %s W","class":"%s"}\n' \
  "$icon" "$util" "$util" "$temp" "$mused" "$mtot" "$power" "$cls"
