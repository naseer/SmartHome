#!/usr/bin/env bash
# Crop the OSD clock regions from /etc/wall-tiles.conf and stack them into one labelled image, so
# you can SEE whether each region still lands on a timestamp. Run after any dashboard layout change.
#   ./show-osd-regions.sh [out.png]      (RUN FROM THE WORKSTATION)
set -euo pipefail
PI="${PI:-wallpi}"
OUT="${1:-osd-regions.png}"
ssh "$PI" 'bash -s' <<'REMOTE' > /dev/null
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/1000
for s in $(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$'); do
  export WAYLAND_DISPLAY="$s"
  grim -g "0,0 1x1" /dev/null 2>/dev/null && break
done
rm -f /tmp/osd_*.png
while read -r name geom; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue;; esac
  grim -g "$geom" "/tmp/osd_${name}.png"
done < /etc/wall-tiles.conf
REMOTE
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
scp -q "$PI:/tmp/osd_*.png" "$TMP/"
if command -v montage >/dev/null 2>&1; then
  montage -label '%f' "$TMP"/osd_*.png -tile 1x -geometry +2+2 -background '#141414' -fill yellow "$OUT"
else
  # no ImageMagick: just report what was captured, the files are the evidence
  ls -l "$TMP"/osd_*.png
  cp "$TMP"/osd_*.png .
  echo ">> ImageMagick not installed; individual crops copied here instead"
  exit 0
fi
echo ">> $OUT -- each strip should show a running timestamp, not scenery"
