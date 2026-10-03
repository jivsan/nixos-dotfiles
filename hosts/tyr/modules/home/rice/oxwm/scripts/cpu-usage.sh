#!/usr/bin/env sh
set -eu

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/oxwm"
state_file="$cache_dir/cpu-prev"
mkdir -p "$cache_dir"

set -- $(awk '/^cpu /{
  total=0
  for(i=2;i<=9;i++) total+=$i
  idle=$5+$6
  print total, idle
}' /proc/stat)

total_now=$1
idle_now=$2

if [ ! -f "$state_file" ]; then
  printf '%s %s\n' "$total_now" "$idle_now" > "$state_file"
  echo "0.0"
  exit 0
fi

set -- $(cat "$state_file")
total_prev=$1
idle_prev=$2

printf '%s %s\n' "$total_now" "$idle_now" > "$state_file"

dt=$((total_now - total_prev))
di=$((idle_now - idle_prev))

if [ "$dt" -le 0 ]; then
  echo "0.0"
  exit 0
fi

awk -v dt="$dt" -v di="$di" 'BEGIN { printf "%.1f\n", ((dt - di) * 100) / dt }'
