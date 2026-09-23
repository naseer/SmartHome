#!/usr/bin/env bash
# Stand up https://ha.naseer.dev in front of Home Assistant. Run ON masn.
#
#   ./setup-tls.sh <duckdns-name>        e.g. ./setup-tls.sh naseer-ha
#
# Prompts for the DuckDNS token on stdin so it never appears in argv or shell history.
#
# PREREQUISITES, both one-time, both in Squarespace:
#     ha                  A      192.168.50.50
#     _acme-challenge.ha  CNAME  <duckdns-name>.duckdns.org
#
# NOTE THE CNAME TARGET HAS NO _acme-challenge PREFIX. DuckDNS holds its single TXT record at the
# APEX of <name>.duckdns.org, not under a _acme-challenge label, so pointing at
# _acme-challenge.<name>.duckdns.org would resolve to nothing and issuance would fail.
#
# ONE CERTIFICATE NAME PER DUCKDNS DOMAIN. DuckDNS allows exactly one TXT value per domain, and a
# multi-name (SAN) certificate has to satisfy every name's challenge simultaneously -- the second
# would overwrite the first. If a second name is ever needed (e.g. proxying Frigate so the Review
# view survives https), register a SECOND DuckDNS domain and give it its own CNAME. Do not try to
# put two names on one.
set -euo pipefail

NAME="${1:?usage: setup-tls.sh <duckdns-name>}"
DOMAIN="ha.naseer.dev"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo ">> checking DNS before touching anything"
a=$(dig +short A "$DOMAIN" | tail -1)
[ "$a" = "192.168.50.50" ] || { echo "!! $DOMAIN resolves to '${a:-nothing}', expected 192.168.50.50"; exit 1; }
c=$(dig +short CNAME "_acme-challenge.$DOMAIN" | tail -1)
[ -n "$c" ] || { echo "!! _acme-challenge.$DOMAIN has no CNAME -- add it in Squarespace first"; exit 1; }
case "$c" in
  _acme-challenge.*) echo "!! CNAME points at '$c' -- drop the _acme-challenge prefix from the TARGET;"
                     echo "   DuckDNS serves its TXT at $NAME.duckdns.org itself"; exit 1;;
  *duckdns.org.)     : ;;
  *)                 echo "!! CNAME points at '$c', expected $NAME.duckdns.org."; exit 1;;
esac
echo "   A -> $a"
echo "   _acme-challenge -> $c"

read -r -s -p "DuckDNS token: " TOKEN; echo
[ -n "$TOKEN" ] || { echo "!! empty token"; exit 1; }

umask 077
printf 'DUCKDNS_TOKEN=%s\n' "$TOKEN" > .env
echo ">> wrote .env (0600, gitignored)"

mkdir -p certs
docker compose -p tls up -d acme

echo ">> issuing the certificate (DNS-01 via DuckDNS; propagation wait is normal)"
# --challenge-alias is THE load-bearing flag. Without it acme.sh writes the TXT at
# _acme-challenge.ha.naseer.dev, which lives in Squarespace, has no API, and fails. With it acme.sh
# writes into the DuckDNS domain and Let's Encrypt follows the one-time CNAME there.
docker exec acme acme.sh --issue --dns dns_duckdns -d "$DOMAIN" \
  --challenge-alias "$NAME.duckdns.org" --server letsencrypt

# acme.sh's internal layout is not what nginx should read. --install-cert gives a stable path that
# survives renewal AND reloads nginx, so a renewed certificate is actually served rather than sitting
# on disk while nginx keeps the expired one in memory.
docker exec acme acme.sh --install-cert -d "$DOMAIN" \
  --key-file       "/acme.sh/$DOMAIN/privkey.pem" \
  --fullchain-file "/acme.sh/$DOMAIN/fullchain.pem" \
  --reloadcmd      "docker exec ha-tls nginx -s reload || true"

docker compose -p tls up -d
echo ">> verifying"
sleep 3
curl -sI "https://$DOMAIN/" --resolve "$DOMAIN:443:192.168.50.50" | head -3 || true
cat <<'NEXT'

NEXT, in Home Assistant (configuration.yaml), then RESTART HA -- a new http: block is not reloadable:

    http:
      use_x_forwarded_for: true
      trusted_proxies:
        - 127.0.0.1
        - ::1

    homeassistant:
      internal_url: "https://ha.naseer.dev"
      external_url: "https://ha.naseer.dev"

external_url is the one that matters: HA Cast uses get_url(require_ssl=True, prefer_external=True),
so until external_url is the LAN-resolving name, casting keeps going through Nabu Casa.

Remote access is UNAFFECTED -- Nabu Casa is an outbound tunnel independent of external_url, and every
notification image/clickAction in this config is a RELATIVE path (audited 2026-09-21), so phones away
from home keep resolving them through the cloud connection.
NEXT
