#!/usr/bin/env bash
# Store LOCAL-ONLY, READ-ONLY UniFi credentials in /opt/stack/.env. Run ON masn.
#
# Create the account first: UniFi UI -> Settings -> Admins & Users -> Add Admin
#   - "Restrict to Local Access Only"  <- REQUIRED. Without it this credential is tied to your
#     Ubiquiti SSO account and would grant cloud + remote access. With it, the blast radius of a
#     leak is read-only access to the local controller from inside the LAN.
#   - Role: Viewer / read-only. Nothing here needs write access.
#   - A unique password, not reused from anything else.
#
# Entered interactively so it never appears on screen, in shell history, in `ps`, or in any log.
set -euo pipefail

ENVF=/opt/stack/.env
if [ ! -f "$ENVF" ]; then
  # Both masn AND the workstation have a ~/SmartHome checkout, so this path looks equally valid
  # from either box. Only masn has /opt/stack. Say which mistake it actually is.
  if [ ! -d /opt/stack ]; then
    echo "!! /opt/stack does not exist -- you are probably NOT on masn."
    echo "   This script must run ON masn:  ssh -t masn '~/SmartHome/masn-stack/set-unifi-creds.sh'"
    echo "   (-t is required: the password prompt needs a pty.)"
  else
    echo "!! $ENVF missing -- run setup-masn.sh first"
  fi
  exit 1
fi

read -rp  "UniFi host [192.168.50.1]: " H; H="${H:-192.168.50.1}"
read -rp  "UniFi local username: " U
read -rsp "UniFi local password: " P; echo

[ -n "$U" ] && [ -n "$P" ] || { echo "!! empty username or password, nothing written"; exit 1; }

tmp="$(mktemp)"
grep -vE '^(UNIFI_HOST|UNIFI_USER|UNIFI_PASSWORD)=' "$ENVF" > "$tmp" || true
{
  printf 'UNIFI_HOST=%s\n' "$H"
  printf 'UNIFI_USER=%s\n' "$U"
  printf 'UNIFI_PASSWORD=%s\n' "$P"
} >> "$tmp"
install -m 600 "$tmp" "$ENVF"; rm -f "$tmp"
unset U P

echo ">> written to $ENVF (mode 600). Verify with: tools/unifi-events.sh 24"
