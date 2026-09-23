#!/usr/bin/env bash
# Stand up https://ha.naseer.dev in front of Home Assistant. Run ON masn.
#
#   ./setup-tls.sh <dedyn-name>        e.g. ./setup-tls.sh naseer
#
# Prompts for the deSEC token on stdin so it never appears in argv or shell history.
#
# PREREQUISITES, both one-time, both in Squarespace:
#     ha                  A      192.168.50.50
#     _acme-challenge.ha  CNAME  _acme-challenge.<dedyn-name>.dedyn.io
# Verify them BEFORE running -- issuance fails confusingly if the CNAME is missing, and Let's
# Encrypt rate-limits repeated failures.
set -euo pipefail

NAME="${1:?usage: setup-tls.sh <dedyn-name>}"
DOMAIN="ha.naseer.dev"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo ">> checking DNS before touching anything"
a=$(dig +short A "$DOMAIN" | tail -1)
[ "$a" = "192.168.50.50" ] || { echo "!! $DOMAIN resolves to '${a:-nothing}', expected 192.168.50.50"; exit 1; }
c=$(dig +short CNAME "_acme-challenge.$DOMAIN" | tail -1)
[ -n "$c" ] || { echo "!! _acme-challenge.$DOMAIN has no CNAME -- add it in Squarespace first"; exit 1; }
echo "   A -> $a"
echo "   _acme-challenge -> $c"

read -r -s -p "deSEC API token: " TOKEN; echo
[ -n "$TOKEN" ] || { echo "!! empty token"; exit 1; }

umask 077
cat > .env <<ENV
DEDYN_TOKEN=$TOKEN
DEDYN_NAME=$NAME.dedyn.io
ENV
echo ">> wrote .env (0600, gitignored)"

mkdir -p certs
docker compose -p tls up -d acme
echo ">> issuing the certificate (DNS-01 via deSEC; propagation wait is normal)"
# --challenge-alias is THE load-bearing flag. Without it acme.sh tries to write the TXT record at
# _acme-challenge.ha.naseer.dev, which lives in Squarespace and has no API, and issuance fails. With
# it, acme.sh writes _acme-challenge.$NAME.dedyn.io in deSEC instead, and Let's Encrypt follows the
# one-time CNAME there. This flag is the entire reason the delegation works.
docker exec acme acme.sh --issue --dns dns_desec -d "$DOMAIN" \
  --challenge-alias "$NAME.dedyn.io" --server letsencrypt

# acme.sh's own layout is not what nginx should read directly -- --install-cert gives a stable path
# that survives renewal, and reloads nginx in place so a renewed cert is actually served.
docker exec acme acme.sh --install-cert -d "$DOMAIN" \
  --key-file       "/acme.sh/$DOMAIN/privkey.pem" \
  --fullchain-file "/acme.sh/$DOMAIN/fullchain.pem" \
  --reloadcmd      "docker exec ha-tls nginx -s reload || true"

docker compose -p tls up -d
echo
echo ">> verifying"
sleep 3
curl -sI "https://$DOMAIN/" --resolve "$DOMAIN:443:192.168.50.50" | head -3 || true
echo
cat <<'NEXT'
NEXT, in Home Assistant (configuration.yaml), then RESTART HA (a new http: block is not reloadable):

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

Remote access is UNAFFECTED -- Nabu Casa is an outbound tunnel and does not depend on external_url.
Every notification image/clickAction in this config is a RELATIVE path (audited 2026-09-21), so
phones away from home keep resolving them through the cloud connection.
NEXT
