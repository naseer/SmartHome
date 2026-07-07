#!/usr/bin/env bash
# Validate HA config, then hot-reload YAML (automations/scripts/templates/helpers). Run ON masn:
#   ssh masn 'bash ~/SmartHome/masn-stack/homeassistant/ha-reload.sh'
# For automation/script edits this avoids a full restart. Adding a NEW package file or integration
# still needs `sudo docker restart homeassistant`.
set -euo pipefail

ENVF=/opt/stack/.env
[ -f "$ENVF" ] && { set -a; . "$ENVF"; set +a; }
: "${HA_TOKEN:?HA_TOKEN not set in /opt/stack/.env -- run set-ha-token.sh first}"

echo "== validating config (check_config) =="
sudo docker exec homeassistant python -m homeassistant --script check_config -c /config

echo "== reloading YAML config (reload_all) =="
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer ${HA_TOKEN}" \
  http://localhost:8123/api/services/homeassistant/reload_all)
[ "$code" = "200" ] && echo "reload_all: OK" || { echo "reload_all FAILED (HTTP $code)"; exit 1; }
