#!/usr/bin/env bash
# Stand up the masn container stack on a FRESH Ubuntu Server install.
# Run from this stack dir (where docker-compose.yml lives). Needs sudo. Review before running.
set -euo pipefail

STACK_DIR="/opt/stack"

echo ">> [1/6] Install Docker Engine + compose plugin"
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nfs-common
  sudo usermod -aG docker "$USER"
fi

echo ">> [2/6] Create ${STACK_DIR} and copy configs (incl. dotfiles)"
sudo mkdir -p "$STACK_DIR"
sudo cp -r ./. "$STACK_DIR"/
cd "$STACK_DIR"
sudo mkdir -p homeassistant/config frigate/config mosquitto/config mosquitto/data mosquitto/log zigbee2mqtt/data

echo ">> [3/6] Require + secure .env"
[ -f .env ] || { echo "!! .env missing -- copy .env.example to .env and fill it first"; exit 1; }
sudo chmod 600 .env
set -a; source ./.env; set +a

echo ">> [4/6] Create the Mosquitto user (${MQTT_USER})"
sudo touch mosquitto/config/passwd
sudo docker run --rm -v "${STACK_DIR}/mosquitto/config:/mosquitto/config" eclipse-mosquitto:2 \
  mosquitto_passwd -b /mosquitto/config/passwd "$MQTT_USER" "$MQTT_PASSWORD"

echo ">> [5/6] NAS mounts via fstab (idempotent; nofail so boot survives NAS being down)"
declare -A MOUNTS=(
  ["/mnt/nas/backups"]="${NAS_BACKUPS_EXPORT}"
  ["/mnt/nas/frigate"]="${NAS_FRIGATE_EXPORT}"
  ["/mnt/nas/media"]="${NAS_MEDIA_EXPORT}"
)
for mp in "${!MOUNTS[@]}"; do
  sudo mkdir -p "$mp"
  line="${NAS_IP}:${MOUNTS[$mp]} ${mp} nfs defaults,_netdev,nofail 0 0"
  grep -qF " ${mp} " /etc/fstab || echo "$line" | sudo tee -a /etc/fstab > /dev/null
done
sudo mount -a || echo "   (NAS not reachable yet -- nofail means it retries on boot)"

echo ">> [6/6] Bring up the CORE stack (HA + Mosquitto + Postgres)"
sudo docker compose up -d homeassistant mosquitto postgres

echo
echo ">> DONE. HA onboarding at http://<masn-ip>:8123"
echo "   Then paste homeassistant/configuration-snippet.yaml into config/configuration.yaml (recorder->postgres)."
echo "   Enable frigate / zigbee2mqtt in docker-compose.yml as hardware arrives."
