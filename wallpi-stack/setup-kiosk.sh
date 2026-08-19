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
# Pi OS Lite ships no emoji font, and the weather block renders its condition as an emoji. Without
# this the fallback is DejaVu Sans, which shows tofu boxes for most of them.
fc-match ":charset=1f327" 2>/dev/null | grep -qi emoji || {
  echo ">> installing fonts-noto-color-emoji (weather condition icons)"
  sudo apt-get install -y fonts-noto-color-emoji && fc-cache -f >/dev/null
}

echo ">> installing kiosk.service with URL: $KIOSK_URL"
sed "s|KIOSK_URL_PLACEHOLDER|${KIOSK_URL}|" "$UNIT_SRC" | sudo tee /etc/systemd/system/kiosk.service > /dev/null
sudo systemctl daemon-reload

# The console getty on tty1 fights the compositor for the VT; both draw and the screen flickers
# between them. Kiosk owns tty1.
echo ">> masking getty on tty1 so it cannot fight cage for the console"
sudo systemctl disable --now getty@tty1.service 2>/dev/null || true

# WIFI POWER SAVE MUST BE OFF. With it on, the link shows a repeating pattern of one fast packet
# followed by two at ~104ms (the beacon interval) -- 56ms average, 270ms peaks -- with ZERO packet
# loss and a healthy -59 dBm, which is why it looks nothing like a WiFi problem. It buffers the
# video badly: measured 4.47% of samples frozen with it on against 0.22% with it off.
# `iw dev wlan0 set power_save off` DOES NOT STICK -- NetworkManager reapplies its own policy. It
# has to go in the connection profile, and only takes effect on reassociation.
WIFI_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep ':wl' | cut -d: -f1 | head -1)
if [ -n "$WIFI_CON" ]; then
  if [ "$(nmcli -t -f 802-11-wireless.powersave con show "$WIFI_CON" 2>/dev/null)" != "802-11-wireless.powersave:disable" ]; then
    echo ">> disabling wifi power save on '$WIFI_CON' (was buffering the video)"
    sudo nmcli con modify "$WIFI_CON" 802-11-wireless.powersave 2
    sudo nmcli con up "$WIFI_CON" >/dev/null 2>&1 || true
  fi
fi

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
