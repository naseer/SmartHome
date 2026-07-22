#!/usr/bin/env bash
# Push a Lovelace dashboard config into Home Assistant.
#
# Lovelace configs live in HA's .storage (root-owned) and are NOT exposed over the
# REST API, so this drives HA's WebSocket API instead -- which needs only a
# long-lived access token, no sudo. Runs python inside the homeassistant
# container because aiohttp is already there.
#
# Usage:  ./apply-dashboard.sh <url_path> <config.json> [--dry-run]
#   e.g.  ./apply-dashboard.sh dashboard-westacott ../homeassistant/dashboards/westacott.json
#
# Pass "-" as <url_path> to target the built-in default Overview (url_path null),
# which is what every user lands on. Saving to it takes control from HA's
# auto-generated view -- that is how you set a dashboard as default for ALL users
# at once (the per-user `defaultPanel` setting can only ever be set by each user).
#
# Expects the HA token at ~/.ha_token on the docker host (mode 0600).
set -euo pipefail

URL_PATH="${1:?usage: apply-dashboard.sh <url_path> <config.json> [--dry-run]}"
CONFIG_FILE="${2:?usage: apply-dashboard.sh <url_path> <config.json> [--dry-run]}"
DRY_RUN="${3:-}"

[ -f "$HOME/.ha_token" ] || { echo "!! ~/.ha_token not found"; exit 1; }
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONFIG_FILE" \
  || { echo "!! $CONFIG_FILE is not valid JSON"; exit 1; }

docker exec -i \
  -e TOKEN="$(cat "$HOME/.ha_token")" \
  -e URL_PATH="$URL_PATH" \
  -e CONFIG="$(cat "$CONFIG_FILE")" \
  -e DRY_RUN="$DRY_RUN" \
  homeassistant python3 - <<'PY'
import asyncio, json, os, sys, aiohttp

TOKEN = os.environ["TOKEN"]
# "-" targets the built-in default Overview, whose url_path is null.
URL_PATH = None if os.environ["URL_PATH"] == "-" else os.environ["URL_PATH"]
CONFIG = json.loads(os.environ["CONFIG"])
DRY = os.environ.get("DRY_RUN") == "--dry-run"


async def main():
    async with aiohttp.ClientSession() as session:
        async with session.ws_connect("http://127.0.0.1:8123/api/websocket") as ws:
            await ws.receive_json()
            await ws.send_json({"type": "auth", "access_token": TOKEN})
            if (await ws.receive_json()).get("type") != "auth_ok":
                sys.exit("!! auth failed -- check ~/.ha_token")

            counter = 0

            async def call(payload):
                nonlocal counter
                counter += 1
                payload["id"] = counter
                await ws.send_json(payload)
                while True:
                    msg = await ws.receive_json()
                    if msg.get("id") == counter:
                        return msg

            before = await call({"type": "lovelace/config", "url_path": URL_PATH})
            if not before.get("success"):
                # config_not_found on the default Overview just means it is still
                # HA's auto-generated view and has never been taken over.
                print("current: none (auto-generated / not taken over)")
            old = before.get("result") or {}
            print(f"current: {len(old.get('views', []))} view(s), "
                  f"{sum(len(s.get('cards', [])) for v in old.get('views', []) for s in v.get('sections', []))} card(s)")
            print(f"new    : {len(CONFIG.get('views', []))} view(s), "
                  f"{sum(len(s.get('cards', [])) for v in CONFIG.get('views', []) for s in v.get('sections', []))} card(s)")

            if DRY:
                print("DRY RUN -- nothing written.")
                return

            res = await call({"type": "lovelace/config/save",
                              "url_path": URL_PATH, "config": CONFIG})
            if not res.get("success"):
                sys.exit(f"!! save failed: {res.get('error')}")
            print("saved.")

            check = await call({"type": "lovelace/config", "url_path": URL_PATH})
            print("verified:", check.get("success"))


asyncio.run(main())
PY
