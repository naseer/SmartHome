#!/usr/bin/env bash
# Answer ONE question: do parked cars still flicker, or did the yolo_nas_s swap fix it?
#
# The failure this measures (OPEN-THREADS.md thread 1): two adjacent PARKED cars whose boxes
# oscillate between fixed positions. The detector conflates them, so Frigate sees displacement and
# fabricates a steady 1-11 km/h estimated speed. Neither `speed_threshold` (single-frame spikes) nor
# `average_estimated_speed` (inflated by repeated spikes) separates that from a real car.
#
# The robust discriminator is trajectory DIRECTNESS = net displacement (first->last centroid)
# divided by total path length. A real car drives straight down the lane and scores ~0.99-1.0.
# Flicker oscillates in place, so its path length is large while its net displacement is ~0.
#
#   BASELINE, ssdlite, 2026-08-02: 163 of 200 car events were on `driveway` at directness 0.03-0.27.
#   The HA automation's own gate fires only at directness >= 0.5.
#
# Reads `data.path_data` (list of [[x,y], ts]), which Frigate populates ~8 s after lane entry --
# so short events legitimately have no path and are reported separately rather than scored as 0.
#
# Usage: ./frigate-vehicle-flicker.sh [HOURS]        (default 24)
#        FRIGATE_API=http://orin:5000 ./frigate-vehicle-flicker.sh 12
#        LABEL=motorcycle ./frigate-vehicle-flicker.sh

set -euo pipefail

HOURS="${1:-24}"
API="${FRIGATE_API:-http://127.0.0.1:5000}"
LABEL="${LABEL:-car}"
LIMIT="${LIMIT:-2000}"
ZONE="${ZONE:-driveway_lane}"
GATE="${GATE:-0.5}"

AFTER=$(( $(date +%s) - HOURS * 3600 ))

if ! RAW=$(curl -sf "$API/api/events?label=${LABEL}&after=${AFTER}&limit=${LIMIT}&include_thumbnails=0"); then
  echo "ERROR: cannot reach Frigate at $API" >&2
  exit 1
fi

printf '%s' "$RAW" | python3 -c '
import json, math, sys
from collections import defaultdict

events = json.load(sys.stdin)
hours, label, limit, zone, gate = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], float(sys.argv[5])

def directness(path):
    """net displacement / total path length. None when there is no usable track."""
    if not path or len(path) < 2:
        return None
    pts = [p[0] for p in path]
    total = sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))
    if total <= 0:
        return None
    return math.dist(pts[0], pts[-1]) / total

rows = []
for e in events:
    d = e.get("data", {}) or {}
    rows.append({
        "camera": e.get("camera", "?"),
        "direct": directness(d.get("path_data")),
        "speed": d.get("average_estimated_speed") or 0.0,
        "zones": e.get("zones") or [],
        "dur": (e["end_time"] - e["start_time"]) if e.get("end_time") else None,
    })

print(f"window: last {hours}h   label: {label}   events: {len(rows)}")
if len(events) >= limit:
    print(f"!! TRUNCATED at limit={limit} -- rerun with a smaller window or LIMIT= higher.")
if not rows:
    print()
    print("No events in this window. Either nothing drove past, or detection is off")
    print("(check `objects.track` includes the label).")
    sys.exit(0)

scored  = [r for r in rows if r["direct"] is not None]
nopath  = [r for r in rows if r["direct"] is None]
flicker = [r for r in scored if r["direct"] <  0.30]
ambig   = [r for r in scored if 0.30 <= r["direct"] < gate]
real    = [r for r in scored if r["direct"] >= gate]

def pct(n):
    return f"{n / len(rows) * 100:5.1f}%"

print()
print("directness = net displacement / total path length")
print(f"  <0.30   FLICKER-LIKE   {len(flicker):>5}  {pct(len(flicker))}")
print(f"  0.30-{gate:<4} AMBIGUOUS   {len(ambig):>5}  {pct(len(ambig))}")
print(f"  >={gate:<5} REAL MOVEMENT {len(real):>5}  {pct(len(real))}")
print(f"  no path_data           {len(nopath):>5}  {pct(len(nopath))}   (too short to score)")

print()
hdr = "camera".ljust(16) + "total".rjust(7) + "flicker".rjust(9)
hdr += "ambig".rjust(7) + "real".rjust(6) + "nopath".rjust(8)
print(hdr)
per = defaultdict(lambda: [0, 0, 0, 0, 0])
for r in rows:
    p = per[r["camera"]]
    p[0] += 1
    if   r["direct"] is None: p[4] += 1
    elif r["direct"] <  0.30: p[1] += 1
    elif r["direct"] <  gate: p[2] += 1
    else:                     p[3] += 1
for cam, p in sorted(per.items(), key=lambda kv: -kv[1][0]):
    print(f"{cam:<16}{p[0]:>7}{p[1]:>9}{p[2]:>7}{p[3]:>6}{p[4]:>8}")

# What the notification automation ACTUALLY gates on: entering the speed zone, then directness.
inzone = [r for r in rows if zone in r["zones"]]
would  = [r for r in inzone if (r["direct"] or 0) >= gate]
saved  = [r for r in inzone if (r["direct"] or 0) <  gate]
print()
print(f"zone `{zone}` (speed_threshold gate -- stationary objects never enter it):")
print(f"  entered zone                 {len(inzone):>5}")
print(f"  ... would NOTIFY (>= {gate})    {len(would):>5}")
print(f"  ... suppressed by the gate   {len(saved):>5}   <- these are the false alarms it catches")

if flicker:
    sp = [r["speed"] for r in flicker if r["speed"] > 0]
    print()
    print(f"fabricated speed on flicker-like events: {len(sp)} of {len(flicker)} report nonzero")
    if sp:
        print(f"  mean {sum(sp)/len(sp):.2f} km/h   max {max(sp):.2f} km/h")

print()
print("BASELINE (ssdlite, 2026-08-02): 163/200 car events on `driveway`, directness 0.03-0.27.")
print("CAVEAT: this tool cannot tell WHICH detector produced an event. Vehicle detection was OFF")
print("        2026-08-02 -> 2026-08-05, and yolo_nas_s replaced ssdlite on 2026-08-04. Any window")
print("        reaching before 2026-08-05 mixes in ssdlite events. Keep it short to judge yolo-nas.")
share = len(flicker) / len(rows)
if not inzone:
    print("READ: nothing entered the speed zone at all -- the automation could not have fired.")
if share >= 0.50:
    print(f"READ: {share:.0%} flicker-like. NOT fixed -- the swap did not solve it.")
elif share >= 0.15:
    print(f"READ: {share:.0%} flicker-like. IMPROVED but not clean; keep the directness gate.")
else:
    print(f"READ: {share:.0%} flicker-like. Looks fixed -- but confirm the window covered")
    print("      daylight and real traffic before trusting it.")
' "$HOURS" "$LABEL" "$LIMIT" "$ZONE" "$GATE"
