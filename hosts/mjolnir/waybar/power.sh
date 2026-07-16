#!/usr/bin/env bash
# waybar power button → rofi menu in the existing hypr theme
choice=$(printf ' lock\n󰍃 logout\n󰜉 reboot\n⏻ poweroff' | rofi -dmenu -p '⏻' -theme ~/.config/hypr/rofi.rasi)
case $choice in
  *lock)     hyprlock ;;
  *logout)   hyprctl dispatch exit ;;
  *reboot)   systemctl reboot ;;
  *poweroff) systemctl poweroff ;;
esac
