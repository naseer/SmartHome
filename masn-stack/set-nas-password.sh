#!/usr/bin/env bash
# Set the NAS SMB password WITHOUT it appearing on screen, in shell history, or in any log.
# Writes /etc/samba/creds-nas (authoritative for the cifs mounts), syncs it into /opt/stack/.env,
# then mounts the NAS shares. Run interactively:  ssh -t masn 'bash ~/SmartHome/masn-stack/set-nas-password.sh'
set -euo pipefail

SMB_USER="${1:-naseer}"
read -rsp "NAS SMB password for ${SMB_USER}: " P; echo

# creds file drives the mount
printf 'username=%s\npassword=%s\n' "$SMB_USER" "$P" | sudo tee /etc/samba/creds-nas >/dev/null
sudo chmod 600 /etc/samba/creds-nas

# keep /opt/stack/.env in sync so a future setup-masn.sh re-run regenerates the same creds
ENVF=/opt/stack/.env
if [ -f "$ENVF" ]; then
  tmp="$(mktemp)"
  grep -v '^NAS_SMB_PASSWORD=' "$ENVF" > "$tmp"
  printf 'NAS_SMB_PASSWORD=%s\n' "$P" >> "$tmp"
  install -m 600 "$tmp" "$ENVF"
  rm -f "$tmp"
fi
unset P

sudo mount -a
echo "--- cifs mounts ---"
findmnt -t cifs -o TARGET,SOURCE || echo "(no cifs mounts -- check the password / NAS reachability)"
