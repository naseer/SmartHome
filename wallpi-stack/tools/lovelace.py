#!/usr/bin/env python3
"""Read/write a Home Assistant Lovelace dashboard config over the websocket API.

  get <url_path>            -> prints the config as JSON
  set <url_path> <file>     -> writes the JSON in <file> as the config

The token comes from HA_TOKEN in the environment so it never appears in argv
(argv is world-readable via /proc).
"""
import asyncio, json, os, sys
import websockets

HA = os.environ.get("HA_URL", "ws://192.168.50.50:8123/api/websocket")
TOKEN = os.environ["HA_TOKEN"]


async def call(msg):
    async with websockets.connect(HA, max_size=32 * 1024 * 1024) as ws:
        await ws.recv()  # auth_required
        await ws.send(json.dumps({"type": "auth", "access_token": TOKEN}))
        auth = json.loads(await ws.recv())
        if auth.get("type") != "auth_ok":
            raise SystemExit(f"auth failed: {auth}")
        await ws.send(json.dumps({"id": 1, **msg}))
        while True:
            r = json.loads(await ws.recv())
            if r.get("id") == 1:
                if not r.get("success", False):
                    raise SystemExit(f"call failed: {json.dumps(r.get('error'), indent=2)}")
                return r.get("result")


def main():
    action = sys.argv[1]
    url_path = sys.argv[2]
    if action == "get":
        cfg = asyncio.run(call({"type": "lovelace/config", "url_path": url_path}))
        print(json.dumps(cfg, indent=2))
    elif action == "set":
        cfg = json.load(open(sys.argv[3]))
        asyncio.run(call({"type": "lovelace/config/save", "url_path": url_path, "config": cfg}))
        print("saved")
    else:
        raise SystemExit("usage: lovelace.py get|set <url_path> [file]")


main()
