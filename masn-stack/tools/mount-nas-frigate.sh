#!/usr/bin/env bash
# Mount the NAS 'frigate' SMB share at /mnt/nas/frigate for Frigate recordings.
#
#   sudo bash /opt/stack/tools/mount-nas-frigate.sh
#
# Reads NAS_IP / NAS_FRIGATE_SHARE / NAS_FRIGATE_SMB_USER / NAS_FRIGATE_SMB_PASSWORD from
# /opt/stack/.env -- no secrets are hard-coded here. Idempotent: safe to re-run.
# Writes the SMB password to a root-only credentials file (NOT to /etc/fstab, which is
# world-readable). Adds a persistent fstab entry so the mount survives reboot.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "!! run as root:  sudo bash $0"; exit 1; }

ENVF=/opt/stack/.env
get() { grep -E "^$1=" "$ENVF" | cut -d= -f2-; }
NAS_IP=$(get NAS_IP)
SHARE=$(get NAS_FRIGATE_SHARE)
SMB_USER=$(get NAS_FRIGATE_SMB_USER)
SMB_PASS=$(get NAS_FRIGATE_SMB_PASSWORD)
[ -n "$NAS_IP" ] && [ -n "$SHARE" ] && [ -n "$SMB_USER" ] && [ -n "$SMB_PASS" ] \
  || { echo "!! missing NAS_* keys in $ENVF"; exit 1; }

CRED=/etc/cifs-credentials/frigate
install -d -m 700 /etc/cifs-credentials
( umask 177; printf 'username=%s\npassword=%s\n' "$SMB_USER" "$SMB_PASS" > "$CRED" )
chmod 600 "$CRED"

MP=/mnt/nas/frigate
mkdir -p "$MP"
mountpoint -q "$MP" && umount "$MP" || true

OPTS="credentials=$CRED,uid=0,gid=0,file_mode=0664,dir_mode=0775,nofail,_netdev"
WORKVERS=""
for V in 3.1.1 3.0; do
  if mount -t cifs "//$NAS_IP/$SHARE" "$MP" -o "$OPTS,vers=$V" 2>/tmp/cifs_err; then
    WORKVERS=$V; break
  fi
done
[ -n "$WORKVERS" ] || { echo "!! MOUNT FAILED:"; cat /tmp/cifs_err; exit 1; }
echo "mounted //$NAS_IP/$SHARE at $MP (vers=$WORKVERS)"

# persistent fstab entry (idempotent: drop any prior line for this mountpoint first)
sed -i '\#[[:space:]]/mnt/nas/frigate[[:space:]]#d' /etc/fstab
echo "//$NAS_IP/$SHARE $MP cifs $OPTS,vers=$WORKVERS 0 0" >> /etc/fstab
echo "fstab entry written."

T="$MP/.frigate_write_test"
if touch "$T" 2>/dev/null && rm -f "$T"; then echo "WRITE OK"; else
  echo "!! WRITE FAILED -- check that $SMB_USER has write access to the share"; exit 1; fi
echo "--- free space ---"; df -h "$MP" | tail -1
