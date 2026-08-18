#!/usr/bin/env bash
# Install the Masjid Quba prayer-times job on masn. RUN ON MASN.
#
# NO SUDO, DELIBERATELY. masn (unlike wallpi) requires a password for sudo, which a non-interactive
# session cannot supply. Everything here lives in paths the login user already owns, and scheduling
# uses the USER CRONTAB rather than a systemd unit -- systemd --user would need `loginctl
# enable-linger` to survive logout, which is itself privileged.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

install -d /opt/stack/tools /opt/stack/state /opt/stack/logs
install -m 755 "$HERE/tools/masjid-prayer-times.py" /opt/stack/tools/masjid-prayer-times.py

CMD='set -a; . /opt/stack/.env; set +a; /usr/bin/python3 /opt/stack/tools/masjid-prayer-times.py >> /opt/stack/logs/masjid-prayer-times.log 2>&1'

# Hourly, but only ONE network fetch a day -- the script re-publishes from cache otherwise. HA
# forgets REST-API states across a restart, so a purely daily job would leave the wall blank for up
# to 24h. Minute 17 rather than 0 so it does not pile onto every other hourly job.
LINE1="17 * * * * $CMD"
LINE2="@reboot $CMD"

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
crontab -l 2>/dev/null | grep -v 'masjid-prayer-times' > "$TMP" || true
printf '%s\n%s\n' "$LINE1" "$LINE2" >> "$TMP"
crontab "$TMP"

echo ">> installed. crontab now:"
crontab -l | grep masjid | sed 's/^/   /'
echo ">> running once:"
set -a; . /opt/stack/.env; set +a
/usr/bin/python3 /opt/stack/tools/masjid-prayer-times.py
