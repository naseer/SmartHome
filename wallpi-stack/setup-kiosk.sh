#!/usr/bin/env bash
# Install the wall-display kiosk (cage + Chromium) on the Pi. RUN ON THE PI.
#
#   KIOSK_URL=http://192.168.50.50:8123/wall-display/cameras ./setup-kiosk.sh
#
# Deliberately NOT a desktop environment. `cage` runs exactly one fullscreen app with no window
# manager, taskbar or way to switch away -- the requirement was "no other accidental UI possible".
set -euo pipefail

KIOSK_URL="${KIOSK_URL:-http://192.168.50.50:8123/wall-display/cameras}"
UNIT_SRC="$(dirname "$0")/kiosk.service"
[ -f "$UNIT_SRC" ] || { echo "!! kiosk.service not found next to this script"; exit 1; }
command -v cage >/dev/null || { echo "!! cage not installed"; exit 1; }
command -v chromium >/dev/null || { echo "!! chromium not installed"; exit 1; }

echo ">> installing kiosk.service with URL: $KIOSK_URL"
sed "s|KIOSK_URL_PLACEHOLDER|${KIOSK_URL}|" "$UNIT_SRC" | sudo tee /etc/systemd/system/kiosk.service > /dev/null
sudo systemctl daemon-reload

# The console getty on tty1 fights the compositor for the VT; both draw and the screen flickers
# between them. Kiosk owns tty1.
echo ">> masking getty on tty1 so it cannot fight cage for the console"
sudo systemctl disable --now getty@tty1.service 2>/dev/null || true

sudo systemctl enable kiosk.service >/dev/null
sudo systemctl restart kiosk.service
sleep 6
systemctl is-active kiosk.service | sed 's/^/   kiosk: /'

cat <<'EOF'

>> The display should now show the Home Assistant login page.
   Log in ONCE with a keyboard; the session persists in /home/naseer/.kiosk-profile and survives
   reboots as long as that directory does.

   Logs:      journalctl -u kiosk -f
   Restart:   sudo systemctl restart kiosk
   Stop:      sudo systemctl stop kiosk      (returns you to a black VT, not a console --
                                              getty@tty1 is disabled; ssh in instead)
EOF
