#!/usr/bin/env bash
# Store a Home Assistant long-lived access token in /opt/stack/.env WITHOUT it appearing on screen,
# in shell history, or in any log. Generate the token in HA:
#   Profile (bottom-left) -> Security -> Long-lived access tokens -> Create Token.
# Run interactively:  ssh -t masn 'bash ~/SmartHome/masn-stack/set-ha-token.sh'
set -euo pipefail

ENVF=/opt/stack/.env
[ -f "$ENVF" ] || { echo "!! $ENVF missing -- run setup-masn.sh first"; exit 1; }

read -rsp "HA long-lived access token: " T; echo
tmp="$(mktemp)"
grep -v '^HA_TOKEN=' "$ENVF" > "$tmp" || true
printf 'HA_TOKEN=%s\n' "$T" >> "$tmp"
install -m 600 "$tmp" "$ENVF"; rm -f "$tmp"
unset T
echo "HA_TOKEN stored in $ENVF (600). Test: ssh masn 'bash ~/SmartHome/masn-stack/homeassistant/ha-reload.sh'"
