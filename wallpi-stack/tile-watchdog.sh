#!/usr/bin/env bash
# Detect a wall tile whose video has stalled, and restart the kiosk to recover it.
#
# THE FAILURE THIS EXISTS FOR (observed 2026-08-17, after a reboot):
# The backyard tile froze on a single frame while the other four played normally. go2rtc was still
# receiving AND sending that stream (recv 576.3 -> 578.0 MB over 12s), so neither the camera nor the
# server was at fault -- the BROWSER'S MSE decoder had stalled and never recovered on its own. From
# across a room a frozen tile is indistinguishable from a quiet driveway, so this can persist
# unnoticed for hours. Restarting the kiosk clears it.
#
# HOW LIVENESS IS DETECTED: every Reolink stream burns an OSD CLOCK into the video that ticks once a
# second. Two grabs of just that clock, a few seconds apart, are byte-identical if and only if the
# stream is not advancing. This is immune to the obvious false positive -- a genuinely still scene
# at 3am still has a running clock, whereas a naive whole-tile pixel diff would call it frozen.
#
# Grabbing only the clock (a ~500x45 region) rather than whole 4K frames also keeps this cheap
# enough to run on a Pi that is already decoding five streams.
#
# Tile regions live in /etc/wall-tiles.conf; they are LAYOUT-DEPENDENT and must be updated if the
# dashboard is rearranged. Verify with:  wallpi-stack/tools/show-osd-regions.sh

set -uo pipefail

CONF="${CONF:-/etc/wall-tiles.conf}"
STATE_DIR=/var/lib/tile-watchdog
STATE="$STATE_DIR/state"
GAP="${GAP:-6}"                              # seconds between the two grabs
FAIL_RESTART="${FAIL_RESTART:-3}"            # consecutive detections before acting
RESTART_COOLDOWN="${RESTART_COOLDOWN:-900}"  # never restart more often than this
DRY_RUN="${DRY_RUN:-0}"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

mkdir -p "$STATE_DIR"
fails=0
last_restart=0
# shellcheck disable=SC1090
[ -f "$STATE" ] && . "$STATE"

log() { echo "$*"; }

# cage's socket is usually wayland-0 but the number can bump across restarts.
find_display() {
    local s
    for s in $(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$'); do
        if WAYLAND_DISPLAY="$s" grim -g "0,0 1x1" /dev/null 2>/dev/null; then
            echo "$s"; return 0
        fi
    done
    return 1
}

WD=$(find_display) || {
    # Not a tile fault: the compositor is gone or wedged. mailbox-watchdog owns that case, and
    # acting here would just fight it.
    log "no responsive wayland display -- leaving this to mailbox-watchdog"
    exit 0
}
export WAYLAND_DISPLAY="$WD"

# GRACE PERIOD AFTER A KIOSK RESTART. Tiles take 40-60s to negotiate their streams, and a tile that
# has not started yet is not a stalled tile. Observed 2026-08-18: a check landing in that window
# logged `STALLED: backyard (live=4 frozen=1)` and incremented the counter -- three of those in a
# row would have restarted the kiosk, which would restart the streams, which would trip it again.
# The boot grace in the timer (OnBootSec) does not cover a restart of the unit alone.
KIOSK_MIN_UPTIME="${KIOSK_MIN_UPTIME:-120}"
started=$(systemctl show kiosk.service -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
if [ -n "$started" ] && [ "$started" -gt 0 ] 2>/dev/null; then
    now_mono=$(awk '{printf "%d", $1 * 1000000}' /proc/uptime)
    age=$(( (now_mono - started) / 1000000 ))
    if [ "$age" -lt "$KIOSK_MIN_UPTIME" ]; then
        log "kiosk started ${age}s ago (< ${KIOSK_MIN_UPTIME}s) -- still bringing streams up, skipping"
        exit 0
    fi
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# `mode single_stream` in the conf: the wall renders ONE composited stream, so every clock freezes
# together and the mixed-picture rule below would never fire. See wall-tiles.conf.
SINGLE_STREAM=0
grep -qE '^[[:space:]]*mode[[:space:]]+single_stream' "$CONF" 2>/dev/null && SINGLE_STREAM=1

grab() {  # grab <pass> ; fills $TMP/<pass>_<name>.png
    local pass="$1" name geom
    while read -r name geom; do
        [ -z "${name:-}" ] && continue
        case "$name" in \#*|mode) continue;; esac
        grim -g "$geom" "$TMP/${pass}_${name}.png" 2>/dev/null
    done < "$CONF"
}

grab a
sleep "$GAP"
grab b

live=0; frozen=0; frozen_names=""
while read -r name geom; do
    [ -z "${name:-}" ] && continue
    case "$name" in \#*|mode) continue;; esac
    A="$TMP/a_${name}.png"; B="$TMP/b_${name}.png"
    [ -s "$A" ] && [ -s "$B" ] || continue      # a failed grab is not evidence of a stall
    if [ "$(md5sum < "$A")" = "$(md5sum < "$B")" ]; then
        frozen=$((frozen + 1)); frozen_names="$frozen_names $name"
    else
        live=$((live + 1))
    fi
done < "$CONF"

# Requiring at least one LIVE tile is what makes this safe: if every tile is frozen the fault is the
# display, the compositor or the network, and restarting the kiosk is the wrong (and possibly
# looping) response. Only a MIXED picture proves the wall works and one stream is stuck.
# In single-stream mode all-frozen IS the stall signal, so only "nothing frozen" is healthy.
if [ "$SINGLE_STREAM" = 1 ]; then
    healthy_condition=$([ "$frozen" -eq 0 ] && echo yes || echo no)
else
    healthy_condition=$([ "$frozen" -eq 0 ] || [ "$live" -eq 0 ] && echo yes || echo no)
fi
if [ "$healthy_condition" = yes ]; then
    if [ "$fails" -gt 0 ]; then
        log "all tiles healthy again (live=$live frozen=$frozen); clearing"
        printf 'fails=0\nlast_restart=%s\n' "$last_restart" > "$STATE"
    fi
    exit 0
fi

fails=$((fails + 1))
log "STALLED ($fails):$frozen_names  (live=$live frozen=$frozen)"
printf 'fails=%s\nlast_restart=%s\n' "$fails" "$last_restart" > "$STATE"

[ "$fails" -ge "$FAIL_RESTART" ] || exit 0

now=$(date +%s)
since=$((now - last_restart))
if [ "$last_restart" -ne 0 ] && [ "$since" -lt "$RESTART_COOLDOWN" ]; then
    log "would restart, but last restart was ${since}s ago (cooldown ${RESTART_COOLDOWN}s) -- holding"
    exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
    log "DRY_RUN: would restart kiosk.service to recover$frozen_names"
    exit 0
fi

log "restarting kiosk.service to recover$frozen_names"
printf 'fails=0\nlast_restart=%s\n' "$now" > "$STATE"
sudo systemctl restart kiosk.service
