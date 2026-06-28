#!/usr/bin/env bash
# Copy masn's Jellyfin media library to the NAS BEFORE the wipe.
# Run ON masn, inside tmux (~1 h for 382 GB over 1GbE). Review before running.
set -euo pipefail

# ---- EDIT once the NAS is up ----
NAS_IP="192.168.x.x"
NAS_MEDIA_EXPORT="/mnt/pool/media"        # NFS export path on the NAS
# ---------------------------------

SRC="/local/mnt/workspace/naseer/jellyfin/"   # trailing slash = copy contents
MNT="/mnt/nas-media"

echo ">> Mounting NAS media share (${NAS_IP}:${NAS_MEDIA_EXPORT}) at ${MNT}"
sudo mkdir -p "$MNT"
mountpoint -q "$MNT" || sudo mount -t nfs "${NAS_IP}:${NAS_MEDIA_EXPORT}" "$MNT"

echo ">> Source size + file count:"
du -sh "$SRC"
SRC_COUNT=$(find "$SRC" -type f | wc -l)
echo "   source files: $SRC_COUNT"

echo ">> Dry run (no changes)…"
rsync -aHAX --dry-run --stats "$SRC" "$MNT/" | tail -n 15

read -r -p ">> Proceed with the REAL copy? [y/N] " ok
[ "$ok" = "y" ] || { echo "Aborted."; exit 1; }

echo ">> Copying…"
rsync -aHAX --info=progress2 "$SRC" "$MNT/"

echo ">> Verify: file count"
DST_COUNT=$(find "$MNT" -type f | wc -l)
echo "   source=$SRC_COUNT  dest=$DST_COUNT"
[ "$SRC_COUNT" -eq "$DST_COUNT" ] || { echo "!! COUNT MISMATCH -- DO NOT WIPE"; exit 1; }

echo ">> Verify: checksum sample (10 random files)"
fail=0
while read -r f; do
  s=$(sha256sum "${SRC}${f#./}" | awk '{print $1}')
  d=$(sha256sum "${MNT}/${f#./}" | awk '{print $1}')
  if [ "$s" = "$d" ]; then echo "   OK   ${f#./}"; else echo "   FAIL ${f#./}"; fail=1; fi
done < <(cd "$SRC" && find . -type f | shuf | head -10)
[ "$fail" -eq 0 ] || { echo "!! CHECKSUM MISMATCH -- DO NOT WIPE"; exit 1; }

echo ">> DONE. Media verified on the NAS. Safe to proceed to the clean install."
