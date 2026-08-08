#!/usr/bin/env bash
# Store the Frigate+ API key in /opt/stack/.env WITHOUT it appearing on screen, in shell history,
# or in any log. Get the key from https://plus.frigate.video -> Account.
# Run interactively:  ssh -t masn 'bash ~/SmartHome/masn-stack/set-plus-key.sh'
#
# Setting this is the ONLY thing needed to enable Frigate+: on restart Frigate flips
# `plus.enabled` to true and the "Send to Frigate+" button appears on snapshots.
# Requires snapshots.enabled + snapshots.clean_copy (both already true) -- Frigate+ trains on the
# clean, unannotated image, not the one with boxes drawn on it.
set -euo pipefail

ENVF=/opt/stack/.env
[ -f "$ENVF" ] || { echo "!! $ENVF missing -- run setup-masn.sh first"; exit 1; }

read -rsp "Frigate+ API key: " T; echo
[ -n "$T" ] || { echo "!! empty, nothing written"; exit 1; }

tmp="$(mktemp)"
grep -v '^PLUS_API_KEY=' "$ENVF" > "$tmp" || true
printf 'PLUS_API_KEY=%s\n' "$T" >> "$tmp"
install -m 600 "$tmp" "$ENVF"; rm -f "$tmp"
unset T
echo "PLUS_API_KEY stored in $ENVF (600)."
echo "Now apply it:  cd /opt/stack && docker compose up -d frigate"
echo "Verify:        curl -s http://127.0.0.1:5000/api/config | grep -o '\"plus\":[^}]*}'"
