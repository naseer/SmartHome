#!/usr/bin/env bash
# Install the wall display watchdogs. RUN ON THE PI.
#
#   ./setup-watchdog.sh            install and enable both
#   DRY_RUN=1 ./setup-watchdog.sh  install, but log only -- never restart or reboot
#
# TWO SEPARATE FAULTS, TWO SEPARATE WATCHDOGS -- they are not redundant:
#
#   mailbox-watchdog  the VideoCore firmware mailbox wedges, the hardware decoder stops, and the
#                     WHOLE wall freezes. Kernel and SSH stay healthy, so a hardware watchdog never
#                     fires. Remedy: restart the kiosk, then reboot.
#
#   tile-watchdog     ONE stream's MSE decoder stalls in the browser while the others play. The
#                     server is still sending it. Remedy: restart the kiosk. A reboot would be
#                     overkill and the mailbox probe cannot see this at all.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIOSK_USER="${KIOSK_USER:-naseer}"

# --- mailbox watchdog (runs as root: it must be able to reboot) --------------------------------
sudo install -m 755 "$HERE/mailbox-watchdog.sh" /usr/local/sbin/mailbox-watchdog.sh
sudo install -m 644 "$HERE/mailbox-watchdog.service" /etc/systemd/system/mailbox-watchdog.service
sudo install -m 644 "$HERE/mailbox-watchdog.timer"   /etc/systemd/system/mailbox-watchdog.timer

# --- tile watchdog (runs as the kiosk user: grim needs that user's wayland socket) -------------
sudo install -m 755 "$HERE/tile-watchdog.sh" /usr/local/bin/tile-watchdog.sh
sudo install -m 644 "$HERE/tile-watchdog.service" /etc/systemd/system/tile-watchdog.service
sudo install -m 644 "$HERE/tile-watchdog.timer"   /etc/systemd/system/tile-watchdog.timer
# Preserve hand-tuned regions: overwriting them on reinstall would silently point the probes at
# scenery, which reads as permanently frozen or permanently live.
if [ -f /etc/wall-tiles.conf ]; then
  echo ">> /etc/wall-tiles.conf exists, leaving it alone (new copy at /etc/wall-tiles.conf.dist)"
  sudo install -m 644 "$HERE/wall-tiles.conf" /etc/wall-tiles.conf.dist
else
  sudo install -m 644 "$HERE/wall-tiles.conf" /etc/wall-tiles.conf
fi
# The service runs unprivileged, so it cannot create this itself.
sudo install -d -o "$KIOSK_USER" -g "$KIOSK_USER" -m 755 /var/lib/tile-watchdog

command -v grim >/dev/null || { echo ">> installing grim (tile-watchdog needs it)"; sudo apt-get install -y grim; }

for u in mailbox-watchdog tile-watchdog; do
  if [ "${DRY_RUN:-0}" = 1 ]; then
    sudo mkdir -p "/etc/systemd/system/$u.service.d"
    printf '[Service]\nEnvironment=DRY_RUN=1\n' | sudo tee "/etc/systemd/system/$u.service.d/dry-run.conf" > /dev/null
  else
    sudo rm -f "/etc/systemd/system/$u.service.d/dry-run.conf"
  fi
done
[ "${DRY_RUN:-0}" = 1 ] && echo ">> DRY_RUN enabled -- both watchdogs will log only"

sudo systemctl daemon-reload
sudo systemctl enable --now mailbox-watchdog.timer tile-watchdog.timer
echo ">> installed:"
systemctl list-timers mailbox-watchdog.timer tile-watchdog.timer --no-pager | sed -n '1,4p'
echo ">> watch:  journalctl -u mailbox-watchdog -u tile-watchdog -f"
