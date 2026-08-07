#!/usr/bin/env bash
# Stand up the Frigate SHADOW stack on the AGX Orin (JetPack 6.2.2 / L4T R36.5.0).
# Run ON THE ORIN, from this stack dir. Needs sudo (the Orin prompts for a password).
#
# Frigate ONLY. mosquitto, Home Assistant, postgres, matter-server and zigbee2mqtt stay on masn --
# see docs/orin-frigate-migration.md section 7. Do not add them here.
set -euo pipefail

STACK_DIR="/opt/stack"
IMAGE="ghcr.io/blakeblackshear/frigate:0.17.2-tensorrt-jp6"

echo ">> [1/6] Verify this is a flashed JetPack 6 board"
[ -f /etc/nv_tegra_release ] || { echo "!! no /etc/nv_tegra_release -- this is not a flashed L4T board"; exit 1; }
grep -q "R36" /etc/nv_tegra_release || { echo "!! expected L4T R36 (JetPack 6). Found:"; cat /etc/nv_tegra_release; exit 1; }
[ -d /usr/local/cuda ] || { echo "!! no CUDA -- the flash did not include the runtime components"; exit 1; }
sed -n '1p' /etc/nv_tegra_release

echo ">> [2/6] Register the nvidia container runtime with Docker"
# JetPack installs nvidia-container-toolkit but does NOT wire it into Docker. Verified missing on
# this board 2026-08-07: no /etc/docker/daemon.json existed at all. Without this the container
# gets no GPU and the TensorRT detector cannot start.
if ! sudo docker info 2>/dev/null | grep -q nvidia; then
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  sleep 3
fi
sudo docker info 2>/dev/null | grep -qi nvidia || { echo "!! nvidia runtime still not registered"; exit 1; }
echo "   nvidia runtime registered"

echo ">> [3/6] Add $USER to the docker group"
# Matches masn, where the login user runs docker without sudo. NOTE this is effectively root-
# equivalent -- it is a deliberate convenience on a single-admin appliance, not a security boundary.
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$USER"
  echo "   added -- LOG OUT AND BACK IN for it to take effect"
fi

echo ">> [4/6] Create ${STACK_DIR}"
sudo mkdir -p "$STACK_DIR"
sudo cp -r ./. "$STACK_DIR"/
sudo chown -R "$USER:$(id -gn)" "$STACK_DIR"   # own it as the invoking user so `source .env` (600) works
cd "$STACK_DIR"
mkdir -p frigate/config

echo ">> [5/6] Require + secure .env"
[ -f .env ] || { echo "!! .env missing -- copy .env.example to .env and fill it, or run tools/sync-secrets-from-masn.sh"; exit 1; }
chmod 600 .env
for k in FRIGATE_RTSP_PASSWORD MASN_LAN_IP MQTT_USER MQTT_PASSWORD NAS_IP \
         NAS_FRIGATE_SHARE NAS_FRIGATE_SMB_USER NAS_FRIGATE_SMB_PASSWORD NAS_FRIGATE_SHADOW_DIR TZ; do
  grep -qE "^${k}=.+" .env || { echo "!! .env is missing a value for ${k}"; exit 1; }
done
echo "   .env present, 600, all required keys set"

echo ">> [6/6] THE GATE -- onnxruntime must expose TensorrtExecutionProvider"
# docs/orin-frigate-migration.md section 3: "If it does not, stop -- nothing downstream will work."
sudo docker pull "$IMAGE"
PROVIDERS=$(sudo docker run --rm --runtime nvidia "$IMAGE" \
  python3 -c "import onnxruntime; print(onnxruntime.get_available_providers())" 2>&1 | tail -1)
echo "   $PROVIDERS"
case "$PROVIDERS" in
  *TensorrtExecutionProvider*) echo "   GATE PASSED" ;;
  *) echo "!! GATE FAILED -- TensorrtExecutionProvider absent. STOP HERE; do not start Frigate."; exit 1 ;;
esac

cat <<'EOF'

Setup complete. NOT started yet -- start it deliberately:

    cd /opt/stack && docker compose up -d && docker compose logs -f frigate

EXPECT THE FIRST START TO BE SLOW. TensorRT compiles an engine for this exact GPU, model and
precision, then caches it under /config/model_cache. Several minutes with no detections is normal.

Then measure against the HD 630 baseline (28-31 ms at detect fps 3):

    FRIGATE_API=http://orin.internal:5000 masn-stack/tools/frigate-detector-stats.sh

This is a SHADOW instance. It publishes to MQTT topic prefix `frigate_orin`, so Home Assistant
does not see it and live automations are untouched. Cutover is a separate, deliberate step.
EOF
