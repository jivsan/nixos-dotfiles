#!/bin/sh
# tyr's wallpaper, drawn with ImageMagick so no binary lives in the repo:
# a neon eclipse with HUD rings over a cyber grid, in the fleet palette
# (pink #ff4fa3, cyan #2de2e6). Kept dark in the middle so text stays readable
# through transparent terminals.
#
#   wallpaper.sh OUT.png [WIDTH HEIGHT]
#
# rice.nix runs this at build time. To try a change without rebuilding:
#   nix shell nixpkgs#imagemagick -c sh wallpaper.sh /tmp/w.png && feh /tmp/w.png
set -eu

out=${1:?usage: wallpaper.sh OUT.png [WIDTH HEIGHT]}
W=${2:-2560}
H=${3:-1440}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pink='#ff4fa3'
cyan='#2de2e6'
void='#03040b'

hz=$((H * 66 / 100))        # horizon
fh=$((H - hz))              # floor height
cx=$((W / 2))
r=$((H * 19 / 100))         # eclipse radius
cy=$((H * 36 / 100))        # eclipse centre
px=$(awk -v r="$r" 'BEGIN { printf "%.2f", r / 274 }')   # scale for line widths

# ── sky: void → indigo, violet haze at the horizon, stars ───────────────────
magick -size "${W}x${hz}" gradient:"${void}-#1a0d3a" "$tmp/sky.png"
magick -size "${W}x$((hz * 40 / 100))" gradient:"${pink}00-${pink}40" "$tmp/haze.png"
magick -seed 7 -size "${W}x${hz}" xc:black +noise Random -colorspace Gray \
  -threshold 99.78% -blur 0x0.8 -level 0,20% \
  \( -size "${W}x${hz}" gradient:white-gray20 \) -compose Multiply -composite \
  "$tmp/stars.png"

# ── eclipse: corona glow, bright rim, dark disc nudged up-right ─────────────
magick -size "$((r * 6))x$((r * 6))" radial-gradient:"${pink}b0-${pink}00" "$tmp/corona.png"
magick -size "$((r * 4))x$((r * 4))" radial-gradient:"${cyan}90-${cyan}00" "$tmp/corona2.png"
magick -size "${W}x${H}" xc:none -fill none \
  -stroke '#e9fdff' -strokewidth "$(awk -v p="$px" 'BEGIN { print 7 * p }')" \
  -draw "circle $cx,$cy $cx,$((cy - r))" "$tmp/rim.png"
magick "$tmp/rim.png" -blur "0x$(awk -v p="$px" 'BEGIN { print 16 * p }')" "$tmp/rimglow.png"
disc="circle $((cx + r * 3 / 100)),$((cy - r * 3 / 100)) $((cx + r * 3 / 100)),$((cy - r * 3 / 100 - r))"

# ── HUD: orbit ellipse, dashed range rings, tick marks, crosshair ───────────
rings=$(awk -v cx="$cx" -v cy="$cy" -v r="$r" 'BEGIN {
  printf "push graphic-context translate %d,%d rotate -16 ", cx, cy
  printf "ellipse 0,0 %.0f,%.0f 0,360 pop graphic-context ", r * 2.05, r * 0.42
  printf "ellipse %d,%d %.0f,%.0f 200,340 ", cx, cy, r * 1.32, r * 1.32
  printf "ellipse %d,%d %.0f,%.0f 20,160 ",  cx, cy, r * 1.32, r * 1.32
}')
dashed=$(awk -v cx="$cx" -v cy="$cy" -v r="$r" 'BEGIN {
  printf "ellipse %d,%d %.0f,%.0f 0,360 ", cx, cy, r * 1.58, r * 1.58
}')
ticks=$(awk -v cx="$cx" -v cy="$cy" -v r="$r" 'BEGIN {
  pi = 3.14159265
  for (a = 0; a < 360; a += 6) {
    l = (a % 30 == 0) ? 0.10 : 0.045
    c = cos(a * pi / 180); s = sin(a * pi / 180)
    printf "line %.1f,%.1f %.1f,%.1f ", cx + c * r * 1.72, cy + s * r * 1.72, cx + c * r * (1.72 + l), cy + s * r * (1.72 + l)
  }
  printf "line %.1f,%d %.1f,%d ", cx - r * 2.6, cy, cx - r * 2.05, cy
  printf "line %.1f,%d %.1f,%d ", cx + r * 2.05, cy, cx + r * 2.6, cy
}')
magick -size "${W}x${H}" xc:none -fill none \
  -stroke "${pink}cc" -strokewidth "$(awk -v p="$px" 'BEGIN { print 2.5 * p }')" -draw "$rings" \
  -stroke "${cyan}aa" -strokewidth "$(awk -v p="$px" 'BEGIN { print 2 * p }')" \
  -draw "stroke-dasharray $(awk -v p="$px" 'BEGIN { printf "%.0f %.0f", 3 * p, 14 * p }') $dashed" \
  -stroke "${cyan}88" -strokewidth "$(awk -v p="$px" 'BEGIN { print 2 * p }')" -draw "$ticks" \
  "$tmp/hud.png"
magick "$tmp/hud.png" -blur "0x$(awk -v p="$px" 'BEGIN { print 5 * p }')" "$tmp/hudglow.png"
front=$(awk -v cx="$cx" -v cy="$cy" -v r="$r" 'BEGIN {
  printf "push graphic-context translate %d,%d rotate -16 ", cx, cy
  printf "ellipse 0,0 %.0f,%.0f 0,180 pop graphic-context ", r * 2.05, r * 0.42
}')
magick -size "${W}x${H}" xc:none -fill none \
  -stroke "${pink}" -strokewidth "$(awk -v p="$px" 'BEGIN { print 3 * p }')" -draw "$front" "$tmp/orbit.png"
magick "$tmp/orbit.png" -blur "0x$(awk -v p="$px" 'BEGIN { print 6 * p }')" "$tmp/orbitglow.png"

# ── floor: perspective grid, fading out towards the horizon ─────────────────
grid=$(awk -v w="$W" -v h="$fh" -v cx="$cx" 'BEGIN {
  n = 13
  for (i = 1; i <= n; i++) {
    y = h * (i / n) ^ 2.1
    printf "line 0,%.1f %d,%.1f ", y, w, y
  }
  s = w / 9
  for (k = -24; k <= 24; k++)
    printf "line %.1f,0 %.1f,%d ", cx + k * s * 0.07, cx + k * s, h
}')
magick -size "${W}x${fh}" xc:none -stroke "$cyan" -strokewidth "$(awk -v p="$px" 'BEGIN { print 2 * p }')" -draw "$grid" \
  \( -size "${W}x${fh}" gradient:'gray(18%)-white' \) \
  -compose DstIn -composite "$tmp/grid.png"
magick "$tmp/grid.png" -blur "0x$(awk -v p="$px" 'BEGIN { print 7 * p }')" "$tmp/gridglow.png"
magick -size "${W}x${fh}" gradient:"#170a30-${void}" "$tmp/floor.png"

# ── assemble ────────────────────────────────────────────────────────────────
magick -size "${W}x${H}" xc:"$void" \
  "$tmp/sky.png"      -geometry +0+0 -compose Over -composite \
  "$tmp/stars.png"    -geometry +0+0 -compose Screen -composite \
  "$tmp/haze.png"     -geometry "+0+$((hz - hz * 40 / 100))" -compose Over -composite \
  "$tmp/corona.png"   -geometry "+$((cx - r * 3))+$((cy - r * 3))" -compose Screen -composite \
  "$tmp/corona2.png"  -geometry "+$((cx - r * 2))+$((cy - r * 2))" -compose Screen -composite \
  "$tmp/hudglow.png"  -geometry +0+0 -compose Screen -composite \
  "$tmp/hud.png"      -geometry +0+0 -compose Over -composite \
  "$tmp/rimglow.png"  -geometry +0+0 -compose Screen -composite \
  "$tmp/rimglow.png"  -geometry +0+0 -compose Screen -composite \
  "$tmp/rim.png"      -geometry +0+0 -compose Over -composite \
  -compose Over -fill "$void" -stroke none -draw "$disc" \
  "$tmp/orbitglow.png" -geometry +0+0 -compose Screen -composite \
  "$tmp/orbit.png"    -geometry +0+0 -compose Over -composite \
  "$tmp/floor.png"    -geometry "+0+${hz}" -compose Over -composite \
  "$tmp/gridglow.png" -geometry "+0+${hz}" -compose Screen -composite \
  "$tmp/gridglow.png" -geometry "+0+${hz}" -compose Screen -composite \
  "$tmp/grid.png"     -geometry "+0+${hz}" -compose Over -composite \
  -compose Over \
  -stroke '#c8fbff' -strokewidth "$(awk -v p="$px" 'BEGIN { print 3 * p }')" -draw "line 0,$hz $W,$hz" \
  \( -size "${W}x$((r / 6))" gradient:"${cyan}00-${cyan}99" \) -geometry "+0+$((hz - r / 6))" -compose Screen -composite \
  \( -size "${W}x$((r / 4))" gradient:"${cyan}88-${cyan}00" \) -geometry "+0+${hz}" -compose Screen -composite \
  \( -size "${W}x${H}" radial-gradient:'white-gray(45%)' \) -geometry +0+0 -compose Multiply -composite \
  -depth 8 -strip -define png:exclude-chunks=date,time "$out"
