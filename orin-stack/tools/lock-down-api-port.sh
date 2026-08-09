#!/usr/bin/env bash
# Gate the Orin's UNAUTHENTICATED Frigate API (:5000) to masn's IP only. Run ON the Orin. Needs sudo.
#
# WHY BOTH THIS AND THE PORT BINDING: docker-compose publishes :5000 on ${ORIN_LAN_IP} rather than
# 0.0.0.0, which keeps it off the tailnet -- but it is still reachable by every device on the LAN,
# and :5000 has no authentication at all. Anyone who can reach it can read every camera's live
# frames, events and recordings. The binding narrows the interface; this narrows the source.
#
# Docker publishes ports by inserting its own DNAT rules into nat/PREROUTING, which are evaluated
# BEFORE filter/INPUT -- so a normal ufw/INPUT rule does NOT block published container ports. The
# rule has to go in the DOCKER-USER chain, which Docker guarantees it will not clobber and which is
# consulted for forwarded container traffic.
set -euo pipefail

# Runs both interactively (sudo prompts) and as root from systemd ExecStartPost, which is how it
# becomes reboot-persistent -- iptables rules do not survive a boot on their own.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

ENVF="${ENVF:-/opt/stack/.env}"
[ -f "$ENVF" ] || { echo "!! $ENVF missing -- run this ON the Orin"; exit 1; }
set -a; . "$ENVF"; set +a
: "${MASN_LAN_IP:?MASN_LAN_IP not set in .env}"

PORT=5000

echo ">> allowing ${MASN_LAN_IP} -> :${PORT}, dropping everyone else"

# Idempotent: delete any prior copies of our rules first, so re-running does not stack duplicates.
while $SUDO iptables -C DOCKER-USER -p tcp --dport "$PORT" -s "$MASN_LAN_IP" -j RETURN 2>/dev/null; do
  $SUDO iptables -D DOCKER-USER -p tcp --dport "$PORT" -s "$MASN_LAN_IP" -j RETURN
done
while $SUDO iptables -C DOCKER-USER -p tcp --dport "$PORT" -j DROP 2>/dev/null; do
  $SUDO iptables -D DOCKER-USER -p tcp --dport "$PORT" -j DROP
done

# Order matters: the ACCEPT/RETURN for masn must be inserted AFTER the DROP so it ends up ABOVE it.
$SUDO iptables -I DOCKER-USER 1 -p tcp --dport "$PORT" -j DROP
$SUDO iptables -I DOCKER-USER 1 -p tcp --dport "$PORT" -s "$MASN_LAN_IP" -j RETURN
# Loopback keeps working for local curl/debugging.
$SUDO iptables -I DOCKER-USER 1 -p tcp --dport "$PORT" -s 127.0.0.1 -j RETURN

echo ">> DOCKER-USER now:"
$SUDO iptables -L DOCKER-USER -n --line-numbers | head -8

cat <<EOF

NOT PERSISTENT ACROSS REBOOT. iptables rules vanish on boot. Make them stick with either:
    sudo apt-get install -y iptables-persistent && sudo netfilter-persistent save
or by adding this script to frigate-stack.service as an ExecStartPost.

VERIFY FROM A THIRD MACHINE (not masn, not the Orin) -- that is the only real test:
    curl -m 5 http://${ORIN_LAN_IP:-<orin-ip>}:${PORT}/api/stats     # must hang or refuse
And from masn it must still work:
    ssh masn 'curl -sf -o /dev/null -w "%{http_code}\n" http://${ORIN_LAN_IP:-<orin-ip>}:${PORT}/api/stats'
EOF
