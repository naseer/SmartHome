#!/usr/bin/env python3
"""Log every 5GHz channel change on the UniFi APs.

WHY THIS EXISTS: the wall display shows brief video skips on a link that is otherwise perfect
(-49 dBm, 433 Mbit/s, 0% packet loss, 6% channel utilisation). Both APs sit on DFS channels chosen
by `auto`, and a DFS radar detection forces the AP to VACATE THE CHANNEL within seconds, dropping
every client briefly. That is the only mechanism consistent with the symptoms.

Proving it from the event log is not possible here: every UniFi event API endpoint 404s on this
firmware (see tools/unifi-events.sh), and the cloud Site Manager only keeps "critical" logs --
"No Logs Available. UniFi Fabric only stores critical system logs."

So instead of hunting the log, watch the OUTCOME. A radar event MOVES THE CHANNEL. Sampling the
channel every couple of minutes and recording changes gives direct, timestamped evidence, and
correlating a change with a skip confirms the diagnosis.

A quiet log after pinning the channels to non-DFS is equally informative: it means the vacates
stopped.

Run from cron on masn; logs to /opt/stack/logs/wifi-channel.log. Prints only on change.
"""
import json
import os
import ssl
import sys
import urllib.request
from datetime import datetime

STATE = os.environ.get("WIFI_CHAN_STATE", "/opt/stack/state/wifi-channels.json")
LOG = os.environ.get("WIFI_CHAN_LOG", "/opt/stack/logs/wifi-channel.log")
DFS = set(range(52, 145))          # 5GHz channels obliged to monitor for radar

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def fetch():
    host = os.environ["UNIFI_HOST"]
    body = json.dumps({"username": os.environ["UNIFI_USER"],
                       "password": os.environ["UNIFI_PASSWORD"]}).encode()
    cj = urllib.request.HTTPCookieProcessor()
    op = urllib.request.build_opener(cj, urllib.request.HTTPSHandler(context=CTX))
    op.open(urllib.request.Request(f"https://{host}/api/auth/login", data=body,
                                   headers={"Content-Type": "application/json"}), timeout=20)
    r = op.open(f"https://{host}/proxy/network/api/s/default/stat/device", timeout=20)
    return json.load(r).get("data", [])


def main():
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        devs = fetch()
    except Exception as e:
        print(f"{now}  !! unifi query failed: {e}", file=sys.stderr)
        return 1

    cur = {}
    for d in devs:
        for r in (d.get("radio_table_stats") or []):
            if r.get("radio") != "na":       # 5GHz only; DFS does not apply to 2.4
                continue
            name = d.get("name") or d.get("model") or d.get("ip")
            cur[name] = r.get("channel")

    try:
        with open(STATE) as f:
            prev = json.load(f)
    except Exception:
        prev = {}

    lines = []
    for ap, ch in sorted(cur.items()):
        was = prev.get(ap)
        if was is None:
            lines.append(f"{now}  {ap}: baseline channel {ch}"
                         f"{'  [DFS]' if ch in DFS else '  [non-DFS]'}")
        elif was != ch:
            # THE EVIDENCE: an unattended channel change on a DFS channel is almost certainly a
            # radar vacate, and every client dropped when it happened.
            tag = "  <-- LEFT A DFS CHANNEL, likely radar" if was in DFS else ""
            lines.append(f"{now}  {ap}: channel {was} -> {ch}{tag}")

    if lines:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            for l in lines:
                f.write(l + "\n")
                print(l)

    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cur, f)
    os.replace(tmp, STATE)
    return 0


sys.exit(main())
