#!/usr/bin/env bash
# Report Frigate detector load: inference latency, offered detection rate, and how
# much of the detector process is actually consumed.
#
# The number that decides whether a bigger model fits is NOT latency alone -- it is
# utilisation = (total detections/sec) x (seconds per inference). One detector process
# is serial, so utilisation >= 1.0 means it cannot keep up and Frigate starts skipping
# frames. Run this before and after a model swap and compare.
#
# Usage: ./frigate-detector-stats.sh [SAMPLES] [INTERVAL_SEC]    (default: 5 samples, 6s apart)

set -euo pipefail

SAMPLES="${1:-5}"
INTERVAL="${2:-6}"
API="${FRIGATE_API:-http://127.0.0.1:5000}"

for i in $(seq 1 "$SAMPLES"); do
  curl -sf "$API/api/stats" || { echo "ERROR: cannot reach Frigate at $API" >&2; exit 1; }
  echo
  [ "$i" -lt "$SAMPLES" ] && sleep "$INTERVAL"
done | python3 -c '
import json, sys

samples = [json.loads(l) for l in sys.stdin if l.strip()]
if not samples:
    sys.exit("no samples")

def mean(xs): return sum(xs) / len(xs)

# Frigate reports one inference_speed per detector (ms) and one detection_fps per camera.
speeds = {}
for s in samples:
    for name, d in s.get("detectors", {}).items():
        speeds.setdefault(name, []).append(d.get("inference_speed") or 0.0)

cams, skipped = {}, {}
for s in samples:
    for name, c in s.get("cameras", {}).items():
        cams.setdefault(name, []).append(c.get("detection_fps") or 0.0)
        skipped.setdefault(name, []).append(c.get("skipped_fps") or 0.0)

version = samples[-1].get("service", {}).get("version", "?")
print(f"samples: {len(samples)}   frigate: {version}")
print()
print("detectors:")
for name, xs in speeds.items():
    print(f"  {name:<10} inference {mean(xs):6.2f} ms  (min {min(xs):.2f} / max {max(xs):.2f})")

print()
print("cameras (detections/sec offered):")
total = 0.0
for name, xs in sorted(cams.items()):
    m = mean(xs)
    total += m
    sk = mean(skipped[name])
    flag = "  <-- SKIPPING FRAMES" if sk > 0 else ""
    print(f"  {name:<16} {m:6.2f}/s   skipped {sk:5.2f}/s{flag}")
label = "TOTAL"
print(f"  {label:<16} {total:6.2f}/s")

print()
avg_ms = mean([mean(x) for x in speeds.values()])
util = total * (avg_ms / 1000.0)
ndet = len(speeds)
print(f"utilisation: {util:.2%} of one detector process ({ndet} configured)")
if util > 0:
    print(f"headroom:    {1.0 / util:.1f}x  -> a model up to ~{avg_ms / util:.0f} ms would still keep up")
if util >= 0.85:
    print("WARNING: at/near saturation -- add a detector or shrink the model")
'
