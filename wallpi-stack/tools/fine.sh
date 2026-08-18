# Detect SHORT stalls: sample two tiles once a second; two identical consecutive grabs means the
# burnt-in clock did not advance for >=1s, i.e. a visible skip. The 6s sampler cannot see these.
export XDG_RUNTIME_DIR=/run/user/1000
for s in $(ls $XDG_RUNTIME_DIR | grep -E '^wayland-[0-9]+$'); do
  export WAYLAND_DISPLAY=$s; grim -g "0,0 1x1" /dev/null 2>/dev/null && break
done
N=${N:-240}; LABEL=${LABEL:-}
T=$(mktemp -d); trap 'rm -rf $T' EXIT
TILES=$(grep -vE '^\s*#|^\s*$' /etc/wall-tiles.conf | awk '{print $1"|"$2" "$3}' | grep -E '^(driveway|west_gate)\|')
declare -A prev stalls total
echo "== $LABEL : $N samples at 1s, started $(date +%H:%M:%S) =="
for i in $(seq 1 $N); do
  echo "$TILES" | while IFS='|' read -r name geom; do
    grim -g "$geom" "$T/$name.png" 2>/dev/null && md5sum < "$T/$name.png" | awk -v n="$name" '{print n, $1}'
  done > "$T/now.txt"
  while read -r name h; do
    if [ "${prev[$name]:-}" = "$h" ]; then
      stalls[$name]=$(( ${stalls[$name]:-0} + 1 ))
      echo "   $(date +%H:%M:%S)  no-advance: $name"
    fi
    [ -n "${prev[$name]:-}" ] && total[$name]=$(( ${total[$name]:-0} + 1 ))
    prev[$name]=$h
  done < "$T/now.txt"
  sleep 1
done
echo "== RESULT ($LABEL) =="
for k in "${!total[@]}"; do
  printf "   %-12s %3d/%3d seconds with no advance  (%.1f%%)\n" "$k" "${stalls[$k]:-0}" "${total[$k]}" \
    "$(awk -v a="${stalls[$k]:-0}" -v b="${total[$k]}" 'BEGIN{print (b?100*a/b:0)}')"
done
