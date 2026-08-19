#!/usr/bin/env bash
# Install the wall-grid compositor on the Orin. RUN ON THE ORIN.
#
# NO SUDO: the Orin requires a password for sudo, so this uses paths the login user owns and the
# USER CRONTAB rather than a systemd unit.
#
# The keepalive matters: the pipeline EXITS whenever go2rtc goes away, because rtspsrc gets EOS
# when the server closes the connection --  "The server closed the connection. Got EOS from element
# pipeline0." A frigate restart therefore kills it silently. The minute-by-minute check restarts it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

install -d /opt/stack/tools /opt/stack/logs
install -m 755 "$HERE/wall-grid.sh" /opt/stack/tools/wall-grid.sh

START='pgrep -x gst-launch-1.0 >/dev/null || (setsid nohup /opt/stack/tools/wall-grid.sh >> /opt/stack/logs/wall-grid.log 2>&1 &)'
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
crontab -l 2>/dev/null | grep -v 'wall-grid' > "$TMP" || true
printf '* * * * * %s\n@reboot sleep 60; %s\n' "$START" "$START" >> "$TMP"
crontab "$TMP"
echo ">> crontab:"; crontab -l | grep wall-grid | sed 's/^/   /'
pgrep -x gst-launch-1.0 >/dev/null || (setsid nohup /opt/stack/tools/wall-grid.sh >> /opt/stack/logs/wall-grid.log 2>&1 &)
sleep 15
echo ">> running: $(pgrep -xc gst-launch-1.0)   serving on :8099: $(ss -ltn 2>/dev/null | grep -c :8099)"
