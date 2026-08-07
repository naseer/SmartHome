#!/usr/bin/env bash
# Copy the Frigate-relevant secrets from masn's /opt/stack/.env to the Orin's, WITHOUT
# printing any value. Run from naahmed-linux (the workstation with ssh access to both).
#
# Values are piped host-to-host through this shell and never echoed, never written to a temp
# file on the workstation, and never land in shell history. Only KEY NAMES are displayed.
#
# Deliberately copies a SUBSET. masn's .env also holds HA_TOKEN, PG_*, NAS_MASN_* and the backups
# share -- none of which Frigate needs, and the Orin should not hold credentials it has no use for.
set -euo pipefail

MASN="${MASN:-masn}"
ORIN="${ORIN:-nvidia@orin.internal}"
SHADOW_DIR="${NAS_FRIGATE_SHADOW_DIR:-orin-shadow}"

# Writes into the STAGING copy of orin-stack in the Orin user's home, NOT /opt/stack.
# /opt is root-owned and the Orin prompts for a sudo password, so nothing here can create it
# unattended. setup-orin.sh copies this whole directory (dotfiles included) into /opt/stack.
STAGE_DIR="${STAGE_DIR:-orin-stack}"

KEYS=(
  FRIGATE_RTSP_PASSWORD
  MASN_LAN_IP
  MQTT_USER
  MQTT_PASSWORD
  NAS_IP
  NAS_FRIGATE_SHARE
  NAS_FRIGATE_SMB_USER
  NAS_FRIGATE_SMB_PASSWORD
  PLUS_API_KEY
  TZ
)

echo ">> Reading these keys from ${MASN}:/opt/stack/.env (values are never displayed):"
printf '     %s\n' "${KEYS[@]}"
echo "     NAS_FRIGATE_SHADOW_DIR   (set locally to: ${SHADOW_DIR})"

PATTERN="$(printf '^%s=|' "${KEYS[@]}")"; PATTERN="${PATTERN%|}"

# Confirm every key actually exists on masn BEFORE writing anything on the Orin, so a partial
# .env is never created. Counting only -- still no values.
FOUND=$(ssh "$MASN" "grep -cE '${PATTERN}' /opt/stack/.env" || echo 0)
if [ "$FOUND" -ne "${#KEYS[@]}" ]; then
  echo "!! expected ${#KEYS[@]} keys on ${MASN}, found ${FOUND}. Aborting without writing anything."
  exit 1
fi

echo ">> Writing ${ORIN}:~/${STAGE_DIR}/.env (mode 600)"
{
  ssh "$MASN" "grep -E '${PATTERN}' /opt/stack/.env"
  printf 'NAS_FRIGATE_SHADOW_DIR=%s\n' "$SHADOW_DIR"
} | ssh "$ORIN" "umask 077; mkdir -p '${STAGE_DIR}'; cat > '${STAGE_DIR}/.env'; chmod 600 '${STAGE_DIR}/.env'"

echo ">> Verifying (key names and value LENGTHS only, never values):"
ssh "$ORIN" "while IFS='=' read -r k v; do [ -n \"\$k\" ] && printf '     %-28s %d chars\n' \"\$k\" \"\${#v}\"; done < '${STAGE_DIR}/.env'"

cat <<EOF

Done. Note NAS_FRIGATE_SHADOW_DIR=${SHADOW_DIR} must ALREADY EXIST inside the frigate share on the
NAS -- SMB will not create it, and the Docker volume mount fails outright rather than falling back
to local disk. Create it before starting the stack.
EOF
