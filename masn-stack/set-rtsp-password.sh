#!/usr/bin/env bash
# Update the Reolink camera password (FRIGATE_RTSP_PASSWORD) on BOTH hosts, in one prompt.
#
# RUN FROM THE WORKSTATION (naahmed-linux), not on masn -- unlike the other set-*.sh here, which are
# on-host. This one exists because the credential must land on TWO machines and they must not drift:
#   - the ORIN runs Frigate (live since 2026-08-09)
#   - MASN still holds the stopped rollback config, which is worthless if its password is stale
#
# Needs a real terminal: `ssh -t` or a normal shell. Claude Code's `!` mode pipes stdin, so the
# hidden prompt gets EOF and the script exits without writing.
#
# All five cameras share ONE admin credential (verified 2026-08-10: same user+password at .86, .151,
# .22, .130, .217), so this is a single value. Rotate it on all five cameras FIRST, then run this.
set -euo pipefail

ORIN="${ORIN:-nvidia@orin.internal}"
MASN="${MASN:-masn}"
KEY=FRIGATE_RTSP_PASSWORD

read -rsp "New Reolink camera password: " P1; echo
read -rsp "Confirm: " P2; echo
[ -n "$P1" ] || { echo "!! empty, nothing written"; exit 1; }
[ "$P1" = "$P2" ] || { echo "!! the two entries differ, nothing written"; exit 1; }

# Piped over stdin, never argv, so it cannot appear in `ps` on either host.
push() {  # $1 = ssh target, $2 = label
  printf '%s' "$P1" | ssh "$1" "
    set -e
    ENVF=/opt/stack/.env
    [ -f \"\$ENVF\" ] || { echo '  !! /opt/stack/.env missing on $2'; exit 1; }
    NEW=\$(cat)
    tmp=\$(mktemp)
    grep -v '^${KEY}=' \"\$ENVF\" > \"\$tmp\" || true
    printf '${KEY}=%s\n' \"\$NEW\" >> \"\$tmp\"
    install -m 600 \"\$tmp\" \"\$ENVF\"; rm -f \"\$tmp\"
    echo \"  $2: written (\$(grep -c . \"\$ENVF\") keys, mode \$(stat -c %a \"\$ENVF\"))\"
  "
}

echo ">> writing to both hosts"
push "$ORIN" "orin"
push "$MASN" "masn"
unset P1 P2

cat <<'EOF'

>> NOT yet applied -- Frigate reads .env at container CREATE time, so a plain restart
   keeps the OLD password. Recreate it:

     ssh nvidia@orin.internal 'cd /opt/stack && docker compose up -d --force-recreate'

   Then confirm the cameras still stream (a wrong password shows as every camera going
   black with 401/unauthorized in the ffmpeg logs):

     ssh nvidia@orin.internal 'docker exec frigate python3 -c "
     import urllib.request,json
     s=json.load(urllib.request.urlopen(\"http://127.0.0.1:5000/api/stats\"))
     print({k: v[\"camera_fps\"] for k,v in s[\"cameras\"].items()})"'

   All six should report ~5 fps (driveway_tele ~5). Zeros mean the password is wrong.
EOF
