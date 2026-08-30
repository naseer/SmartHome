#!/usr/bin/env bash
# Bring the Frigate stack up if it is not running. Driven by frigate-stack-retry.timer.
#
# WHY THIS EXISTS: frigate-stack.service tries for 5 minutes at boot and then gives up FOREVER.
# On 2026-08-21 a power outage took the NAS down with everything else. The Orin came back, the NAS
# did not, the cifs volume mount failed 30 times, the unit exited 1 -- and nothing ever tried again.
# Frigate stayed down for NINE DAYS. The wall showed five dead tiles the whole time and nothing said
# a word.
#
# 5 minutes was never enough patience for a power cut. Many NAS units will not power themselves back
# on after AC loss at all, so the correct retry window is "until someone fixes it", not 5 minutes.
# Type=oneshot cannot use Restart= (systemd rejects it), hence a timer rather than a restart policy.
#
# ALSO RE-APPLIES THE :5000 LOCKDOWN. If the boot unit fails, its ExecStartPost never runs, so a
# stack brought up later by this timer would expose the UNAUTHENTICATED Frigate API to the whole LAN.
# Healing the stack without healing the firewall rule would have quietly turned an outage into a
# disclosure. iptables rules do not survive a reboot, so this must run every time the stack starts.
set -euo pipefail

cd /opt/stack

# Respect a deliberate stop. `systemctl stop frigate-stack` leaves the unit inactive; a boot failure
# or a crash leaves it failed/active. Healing an inactive unit would fight whoever stopped it --
# which is exactly what you do NOT want while someone is mid-maintenance on the NAS.
state_unit=$(systemctl is-active frigate-stack.service 2>/dev/null || true)
if [ "$state_unit" = "inactive" ]; then
  echo ">> frigate-stack is stopped deliberately -- not healing"
  exit 0
fi

state=$(docker inspect -f '{{.State.Status}}' frigate 2>/dev/null || echo missing)
if [ "$state" = "running" ]; then
  exit 0
fi

echo ">> frigate container is '$state' -- bringing the stack up"
docker compose up -d

# Only worth attempting once the container actually exists; a failed mount means there is nothing
# listening on :5000 to protect, and the next tick will try again.
if [ "$(docker inspect -f '{{.State.Status}}' frigate 2>/dev/null || echo missing)" = "running" ]; then
  /opt/stack/tools/lock-down-api-port.sh
fi
