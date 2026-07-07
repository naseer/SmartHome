#!/usr/bin/env bash
# Set NAS SMB password(s) WITHOUT them appearing on screen, in shell history, or in any log.
# Per-share least privilege: svc-frigate -> frigate ; svc-masn -> backups + media.
# Writes the matching /etc/samba/creds-* file (authoritative for the mount), syncs the password
# into /opt/stack/.env, then mounts. Usernames are read from .env.
#
# Run interactively (a TTY is required for the silent prompt):
#   ssh -t masn 'bash ~/SmartHome/masn-stack/set-nas-password.sh'          # both accounts
#   ssh -t masn 'bash ~/SmartHome/masn-stack/set-nas-password.sh frigate'  # just svc-frigate
#   ssh -t masn 'bash ~/SmartHome/masn-stack/set-nas-password.sh masn'     # just svc-masn
set -euo pipefail

ENVF=/opt/stack/.env
[ -f "$ENVF" ] || { echo "!! $ENVF missing -- run setup-masn.sh first"; exit 1; }
set -a; . "$ENVF"; set +a

set_one() {  # $1=label $2=smb_user $3=creds_path $4=env_key
  local label="$1" user="$2" creds="$3" envkey="$4" P
  read -rsp "SMB password for ${user} (${label} share): " P; echo
  # creds file drives the mount
  printf 'username=%s\npassword=%s\n' "$user" "$P" | sudo tee "$creds" >/dev/null
  sudo chmod 600 "$creds"
  # keep .env in sync so a future setup-masn.sh re-run regenerates the same creds
  local tmp; tmp="$(mktemp)"
  grep -v "^${envkey}=" "$ENVF" > "$tmp"
  printf '%s=%s\n' "$envkey" "$P" >> "$tmp"
  install -m 600 "$tmp" "$ENVF"; rm -f "$tmp"
  unset P
}

target="${1:-both}"
case "$target" in
  frigate|both) set_one frigate "$NAS_FRIGATE_SMB_USER" /etc/samba/creds-frigate NAS_FRIGATE_SMB_PASSWORD ;;
esac
case "$target" in
  masn|both) set_one masn "$NAS_MASN_SMB_USER" /etc/samba/creds-masn NAS_MASN_SMB_PASSWORD ;;
esac
case "$target" in
  frigate|masn|both) ;;
  *) echo "usage: $0 [frigate|masn]  (no arg = both)"; exit 2 ;;
esac

sudo mount -a
echo "--- cifs mounts ---"
findmnt -t cifs -o TARGET,SOURCE || echo "(no cifs mounts -- check passwords / NAS reachability / share ACLs)"
