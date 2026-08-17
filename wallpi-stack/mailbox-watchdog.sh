#!/usr/bin/env bash
# Detect a wedged VideoCore firmware mailbox on the wall display Pi and recover from it.
#
# THE FAILURE THIS EXISTS FOR (observed 2026-08-17, one power cycle in two):
# The Pi boots, the kiosk starts, and then anything touching the VideoCore firmware blocks forever
# in uninterruptible sleep -- chromium in `rpm_resume` on the hardware decoder, `vcgencmd` in
# `rpi_firmware_property_list`. Chromium stops getting decoded frames, so THE WALL FREEZES ON ITS
# LAST FRAME while looking completely normal. Only a second reboot clears it.
#
# WHY NOT THE HARDWARE WATCHDOG: bcm2835_wdt + RuntimeWatchdogSec cannot catch this. The kernel
# never stops scheduling -- SSH, systemd and userspace stay perfectly healthy, so systemd keeps
# petting the watchdog while the screen is frozen. Only the firmware is dead. The check has to
# probe the mailbox specifically, which is what this does.
#
# ESCALATION: probe -> restart the kiosk -> reboot. Each step is given time to work before the next.
#
# Run from mailbox-watchdog.timer. Env overrides (all optional):
#   PROBE_TIMEOUT FAIL_RESTART FAIL_REBOOT REBOOT_COOLDOWN DRY_RUN FORCE_FAIL

# NOT `set -e`: probe failure is the normal path here and must be handled, not fatal.
set -uo pipefail

STATE_DIR=/var/lib/mailbox-watchdog
STATE="$STATE_DIR/state"

PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
FAIL_RESTART="${FAIL_RESTART:-3}"      # consecutive failures before restarting the kiosk
FAIL_REBOOT="${FAIL_REBOOT:-6}"        # consecutive failures before rebooting
REBOOT_COOLDOWN="${REBOOT_COOLDOWN:-3600}"   # never reboot-loop faster than this
DRY_RUN="${DRY_RUN:-0}"                # 1 = log what would happen, change nothing
FORCE_FAIL="${FORCE_FAIL:-0}"          # 1 = pretend the probe failed, for testing

mkdir -p "$STATE_DIR"
fails=0
last_reboot=0
# shellcheck disable=SC1090
[ -f "$STATE" ] && . "$STATE"

save_state() {
    printf 'fails=%s\nlast_reboot=%s\n' "$1" "$2" > "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}

log() { echo "$*"; }   # stdout -> journal, via the systemd unit

# --- the probe -------------------------------------------------------------------------------
# NOTE: when the mailbox is wedged, `timeout` returns 124 but CANNOT actually kill vcgencmd --
# uninterruptible sleep ignores signals until the syscall returns. Each failed probe therefore
# leaves one unkillable process behind. That is acceptable at this cadence (a handful before we
# reboot anyway) and is why the probe interval is minutes, not seconds.
mailbox_ok() {
    [ "$FORCE_FAIL" = 1 ] && return 1
    timeout "$PROBE_TIMEOUT" vcgencmd measure_temp >/dev/null 2>&1
}

# Second, independent symptom: processes stuck in D on the firmware or on a runtime-PM resume.
# The mailbox can answer while a consumer is already wedged, so this catches cases the probe alone
# would miss.
blocked_on_firmware() {
    ps -eo stat=,wchan:24=,comm= 2>/dev/null \
      | awk '$1 ~ /^D/ && ($2 ~ /rpi_firmware/ || $2 == "rpm_resume") { n++ } END { exit !(n > 0) }'
}

healthy=1
reason=""
if ! mailbox_ok; then
    healthy=0
    reason="mailbox probe timed out after ${PROBE_TIMEOUT}s"
elif blocked_on_firmware; then
    healthy=0
    reason="processes blocked in D on rpi_firmware/rpm_resume"
fi

if [ "$healthy" = 1 ]; then
    if [ "$fails" -gt 0 ]; then
        log "mailbox healthy again after $fails consecutive failure(s); clearing"
        save_state 0 "$last_reboot"
    fi
    exit 0
fi

fails=$((fails + 1))
log "UNHEALTHY ($fails): $reason"
save_state "$fails" "$last_reboot"

now=$(date +%s)

if [ "$fails" -ge "$FAIL_REBOOT" ]; then
    since=$((now - last_reboot))
    if [ "$last_reboot" -ne 0 ] && [ "$since" -lt "$REBOOT_COOLDOWN" ]; then
        # Rebooting every few minutes would turn one bad boot into an endless cycle, and would
        # destroy the evidence needed to work out what is actually wrong.
        log "would reboot, but last reboot was ${since}s ago (cooldown ${REBOOT_COOLDOWN}s) -- holding"
        exit 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        log "DRY_RUN: would reboot now"
        exit 0
    fi
    log "rebooting: $fails consecutive failures"
    save_state 0 "$now"
    sync
    systemctl reboot
    # If the mailbox is wedged badly enough, a clean shutdown can block on the same firmware.
    # Give it 90s, then force it at the kernel level so the display always comes back.
    sleep 90
    log "clean reboot did not take after 90s -- forcing via sysrq"
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    echo b > /proc/sysrq-trigger 2>/dev/null
    exit 0
fi

if [ "$fails" -eq "$FAIL_RESTART" ]; then
    if [ "$DRY_RUN" = 1 ]; then
        log "DRY_RUN: would restart kiosk.service"
        exit 0
    fi
    # Cheap and usually harmless. It will NOT fix a truly wedged mailbox -- the point is to rule
    # out the milder case (chromium lost the decoder but the firmware is fine) before rebooting.
    log "restarting kiosk.service"
    systemctl restart kiosk.service
fi

exit 0
