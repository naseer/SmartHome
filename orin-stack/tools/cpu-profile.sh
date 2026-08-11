#!/usr/bin/env bash
# Per-process CPU profile of the Frigate container over a fixed interval. Run ON the Orin.
#
# WHY NOT `ps pcpu`: that reports CPU averaged over each process's ENTIRE LIFETIME, so a process
# that is hammering right now but has been idle for a day reads as near zero. That mistake was made
# once already (2026-08-11: the jsmpeg encoders were dismissed, then confirmed innocent by this
# method). This reads /proc/<pid>/stat twice and differences utime+stime, giving true CPU over the
# window.
#
# Usage: ./cpu-profile.sh [SECONDS]      (default 20)
#        LABEL="grid open" ./cpu-profile.sh 30
set -euo pipefail

SECS="${1:-20}"
LABEL="${LABEL:-}"
CID=$(docker ps -qf name=frigate)
[ -n "$CID" ] || { echo "!! frigate container not running"; exit 1; }

read -r _ _ _ _ _ CLK < <(echo "x x x x x $(getconf CLK_TCK)")

snapshot() {
  # pid<TAB>utime+stime<TAB>comm  for every process inside the container's cgroup
  for p in $(docker top "$CID" -eo pid | tail -n +2); do
    [ -r "/proc/$p/stat" ] || continue
    # comm can contain spaces/parens -- take everything after the last ')'
    line=$(cat "/proc/$p/stat" 2>/dev/null) || continue
    rest=${line#*) }
    set -- $rest
    ut=${12}; st=${13}          # utime, stime are fields 14,15 overall -> 12,13 after the comm
    name=$(tr -d '\0' < "/proc/$p/cmdline" 2>/dev/null | head -c 60)
    [ -z "$name" ] && name=$(cat "/proc/$p/comm" 2>/dev/null || echo "?")
    echo "$p	$(( ut + st ))	$name"
  done
}

A=$(snapshot)
sleep "$SECS"
B=$(snapshot)

echo "=== CPU over ${SECS}s ${LABEL:+-- $LABEL} ==="
join -t'	' -j1 <(echo "$A" | sort -t'	' -k1,1) <(echo "$B" | sort -t'	' -k1,1) 2>/dev/null \
 | awk -F'\t' -v s="$SECS" -v clk="$(getconf CLK_TCK)" '
   { d = ($4 - $2) / clk / s * 100; if (d > 0.4) printf "%7.1f%%  %s\n", d, $3 }' \
 | sort -rn | head -18

echo
echo "--- total ---"
join -t'	' -j1 <(echo "$A" | sort -t'	' -k1,1) <(echo "$B" | sort -t'	' -k1,1) 2>/dev/null \
 | awk -F'\t' -v s="$SECS" -v clk="$(getconf CLK_TCK)" \
   '{ t += ($4 - $2) } END { printf "  container: %.1f%% of one core-second per second (%.1f cores)\n", t/clk/s*100, t/clk/s }'
