#!/usr/bin/env sh
# Paints the wallpaper and keeps it fitted to the screen.
#
# An RDP session changes size whenever the Remmina window is resized or made
# fullscreen, and a wallpaper is only painted for the size the screen has at
# that moment. So after the first paint this waits for RandR screen-change
# events (xev) and paints again after each one.
img="$HOME/.local/share/wallpapers/tyr-neon.png"
pidfile="${XDG_RUNTIME_DIR:-/tmp}/tyr-wallpaper-${DISPLAY#:}.pid"

# The xrandr query makes the server bring its monitor layout up to date first;
# without it feh can still be told the old size and paint only that area.
paint() {
  xrandr >/dev/null 2>&1
  feh --no-fehbg --bg-fill "$img"
}

# Only one watcher per session: oxwm runs autostart again on Mod+Shift+R.
if [ -r "$pidfile" ]; then
  old=$(cat "$pidfile")
  pkill -P "$old" 2>/dev/null
  kill "$old" 2>/dev/null
fi
echo $$ > "$pidfile"

paint
xev -root -event randr 2>/dev/null | while read -r line; do
  case "$line" in
    RRScreenChangeNotify*)
      # A resize arrives as more than one event, so paint once the server
      # should have settled and once more a little later. Painting the same
      # image twice is invisible.
      sleep 0.5
      paint
      sleep 1.5
      paint
      ;;
  esac
done
