#!/bin/sh
# mjolnir's two wallpapers, drawn by wallpaper-draw.sh next to this file
# (ImageMagick):
#
#   wall.png       Dell (main screen)    the neon eclipse: pink corona, cyan grid
#   wall-cyan.png  BenQ (second screen)  its twin with the two colours swapped
#
# The PNGs are kept next to this file because hyprland.lua and hyprlock.conf
# read them from ~/.config/hypr. Run this again after changing wallpaper-draw.sh:
#   sh wallpaper.sh            (writes into this folder)
#   sh wallpaper.sh /some/dir  (writes somewhere else, to look first)
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
draw="$here/wallpaper-draw.sh"
out=${1:-$here}

sh "$draw" "$out/wall.png" 2560 1440

# The twin: same script, pink and cyan trading places.
sed -e "s/^pink='#ff4fa3'/pink='#2de2e6'/" -e "s/^cyan='#2de2e6'/cyan='#ff4fa3'/" "$draw" \
  | sh -s "$out/wall-cyan.png" 1920 1080
