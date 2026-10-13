#!/usr/bin/env bash
# Waybar GPU blocks for the RTX 4060 Ti via nvidia-smi
#   gpu.sh        load:    "<icon> 37%"
#   gpu.sh mem    memory:  "<icon> 6.3/8.0 GB"   (what Octane runs out of first)
# Both blocks carry the same tooltip.
what=${1:-load}
card=$'\U000f08ae'   # nerd-font graphics card
chip=$''       # nerd-font chip

data=$(nvidia-smi \
  --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw \
  --format=csv,noheader,nounits 2>/dev/null | head -n 1)

if [ -z "$data" ]; then
  printf '{"text":"%s n/a","tooltip":"nvidia-smi unavailable","class":"gpu"}\n' "$card"
  exit 0
fi

util=$(echo "$data"  | awk -F', *' '{print $1}')
temp=$(echo "$data"  | awk -F', *' '{print $2}')
mused=$(echo "$data" | awk -F', *' '{print $3}')
mtot=$(echo "$data"  | awk -F', *' '{print $4}')
power=$(echo "$data" | awk -F', *' '{printf "%.0f", $5}')
mpct=$(( ${mused:-0} * 100 / ${mtot:-1} ))

tooltip=$(printf 'GPU   %s%%    %s°C\\nVRAM  %s / %s MiB  (%s%%)\\nPower %s W' \
  "$util" "$temp" "$mused" "$mtot" "$mpct" "$power")

if [ "$what" = mem ]; then
  # turns pink when the card is nearly full
  cls="vram"
  [ "$mpct" -ge 85 ] && cls="vram-high"
  text=$(awk -v u="$mused" -v t="$mtot" 'BEGIN { printf "%.1f/%.1f GB", u / 1024, t / 1024 }')
  printf '{"text":"%s %s","tooltip":"%s","class":"%s"}\n' "$chip" "$text" "$tooltip" "$cls"
else
  # turns pink under heavy load
  cls="gpu"
  [ "${util:-0}" -ge 80 ] && cls="gpu-hot"
  printf '{"text":"%s %s%%","tooltip":"%s","class":"%s"}\n' "$card" "$util" "$tooltip" "$cls"
fi
