#!/usr/bin/env bash
# Capture what the wall display is actually showing, and copy it here. RUN FROM THE WORKSTATION.
#
#   ./screenshot.sh [outfile.png]
#
# WHY THIS EXISTS: iterating on the wall layout otherwise means asking a human to photograph the
# monitor and describe it, which is a minutes-long round trip per attempt and loses detail. `grim`
# talks to cage's wlr-screencopy protocol and grabs the real framebuffer, so a layout change can be
# checked in seconds.
#
# Needs `grim` on the Pi (apt install grim) and the kiosk running -- grim captures the compositor's
# output, so if cage is not up there is nothing to capture.
set -euo pipefail

PI="${PI:-wallpi}"
OUT="${1:-wall.png}"

ssh "$PI" 'bash -s' <<'REMOTE'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/1000
# cage's socket is normally wayland-0, but do not hardcode it -- a restart can bump the number.
for S in $(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$'); do
  export WAYLAND_DISPLAY="$S"
  if grim /tmp/wall-shot.png 2>/dev/null; then exit 0; fi
done
echo "!! grim failed on every wayland socket -- is the kiosk running? (systemctl status kiosk)" >&2
exit 1
REMOTE

scp -q "$PI:/tmp/wall-shot.png" "$OUT"
# `identify` needs ImageMagick, which is not on every workstation; `file` reports PNG dimensions
# without it, so this never has to say "size unknown".
DIM=$(identify -format '%wx%h' "$OUT" 2>/dev/null \
      || file -b "$OUT" 2>/dev/null | grep -oE '[0-9]+ x [0-9]+' | tr -d ' ' \
      || echo '?')
echo ">> $OUT  ($DIM)"
