#!/usr/bin/env bash
# UniFi network diagnostics for the recurring multi-camera dropouts (OPEN-THREADS.md thread 7).
#
# WHAT THIS DOES NOT DO: fetch the event/alarm log. Every documented path for it 404s on this
# firmware (UniFi OS 5.1.19 / UCG Fiber), with an `admin` role, not just readonly:
#     GET  /proxy/network/api/s/default/stat/event        api.err.NotFound
#     GET  /proxy/network/api/s/default/stat/alarm        api.err.NotFound
#     POST /proxy/network/api/s/default/stat/event        403
#     GET  /proxy/network/v2/api/site/default/system-log  404   (and events/alerts/notifications)
# Elevating the account does NOT help -- the endpoints are gone, not forbidden. Read the system log
# in the UI instead. Do not go hunting for these paths again without new information.
#
# WHAT IT DOES: everything the API still exposes that bears on the dropouts -- device uptimes (did
# anything reboot?), PoE draw vs budget (is it shedding?), per-port errors and link speeds (bad
# cable?), and which switch port every camera is on (shared upstream?).
#
# Reads UNIFI_HOST/USER/PASSWORD from /opt/stack/.env (see set-unifi-creds.sh). Run ON masn.
set -euo pipefail

ENVF="${ENVF:-/opt/stack/.env}"
[ -f "$ENVF" ] || { echo "!! $ENVF missing -- run set-unifi-creds.sh on masn"; exit 1; }
set -a; . "$ENVF"; set +a
: "${UNIFI_HOST:?run set-unifi-creds.sh first}"
: "${UNIFI_USER:?run set-unifi-creds.sh first}"
: "${UNIFI_PASSWORD:?run set-unifi-creds.sh first}"

JAR="$(mktemp)"; HDR="$(mktemp)"; trap 'rm -f "$JAR" "$HDR"' EXIT

# Credentials go in on stdin (-d @-), never argv, so they cannot show up in `ps`.
# -k because UniFi serves a self-signed cert on the LAN address.
CODE=$(printf '{"username":"%s","password":"%s"}' "$UNIFI_USER" "$UNIFI_PASSWORD" \
  | curl -sk -m 15 -c "$JAR" -D "$HDR" -X POST "https://${UNIFI_HOST}/api/auth/login" \
      -H "Content-Type: application/json" -d @- -o /dev/null -w '%{http_code}')
[ "$CODE" = "200" ] || {
  echo "!! login failed (HTTP $CODE)"
  echo "   401: bad credentials, or the account is not 'local access only' (SSO cannot use this endpoint)"
  echo "   499: rate-limited, or MFA is enabled -- MFA breaks this flow"
  exit 1
}

api() { curl -sk -m 25 -b "$JAR" "https://${UNIFI_HOST}/proxy/network/api/s/default/$1"; }

api stat/device | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("=== DEVICES -- did anything reboot? ===")
for x in sorted(d.get("data", []), key=lambda r: -(r.get("uptime") or 0)):
    print("  %-22s %-10s uptime %6.1f d   temp %-4s  ver %s" % (
        x.get("name"), x.get("model"), (x.get("uptime") or 0)/86400,
        x.get("general_temperature") or "-", x.get("version")))
print()
for x in d.get("data", []):
    pt = x.get("port_table") or []
    if not pt: continue
    used = sum(float(p.get("poe_power") or 0) for p in pt)
    budget = x.get("total_max_power")
    print("=== %s -- PoE %.1f W of %s W (%.0f%%) ===" % (
        x.get("name"), used, budget, 100*used/float(budget) if budget else 0))
    print("  %-5s %-7s %-9s %-9s %-8s" % ("port", "poe_W", "rx_err", "tx_err", "speed"))
    for p in pt:
        if not p.get("up"): continue
        rx, tx = p.get("rx_errors") or 0, p.get("tx_errors") or 0
        flag = "   <-- ERRORS" if (rx or tx) else ""
        print("  %-5s %-7s %-9s %-9s %-8s%s" % (
            p.get("port_idx"), p.get("poe_power"), rx, tx, p.get("speed"), flag))
    print()
'

api stat/sta | python3 -c '
import json, sys
NAMED = {"192.168.50.86":"driveway(TrackMix)","192.168.50.151":"front_door","192.168.50.22":"west_gate",
         "192.168.50.130":"east_gate","192.168.50.217":"backyard","192.168.50.50":"** masn **",
         "192.168.50.200":"** orin **","192.168.50.49":"** NAS **"}
d = json.load(sys.stdin)
rows = []
for c in d.get("data", []):
    ip = c.get("ip") or ""
    if not (NAMED.get(ip) or c.get("is_wired")): continue
    rows.append((c.get("sw_port"), ip, NAMED.get(ip) or (c.get("hostname") or "")[:22], (c.get("uptime") or 0)/3600))
print("=== WIRED CLIENTS by switch port ===")
print("  (several devices on ONE port = an unmanaged switch UniFi cannot see)")
print("  %-5s %-16s %-22s %s" % ("port","ip","device","client uptime"))
for p, ip, nm, up in sorted(rows, key=lambda r: (r[0] is None, r[0] or 0)):
    print("  %-5s %-16s %-22s %.1f h" % (p if p is not None else "-", ip, nm, up))
print()
print("  Camera client uptime NOT resetting across a dropout means the LINK never went down --")
print("  the port stayed up while traffic stopped. That points at STP blocking, not a cable.")
'
