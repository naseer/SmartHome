# The wall display lost its picture, 2026-09-13 onward

## Symptom

Nothing on the monitor. The Pi and the kiosk were both fine the whole time -- Chromium had the
dashboard loaded (`Wall - Home Assistant`, verified over the DevTools port), the tile watchdog was
running, power was clean (`throttled=0x0`), 45 C, no failed units. What was missing was a SCREEN:

    card1-HDMI-A-1   status=disconnected   edid=0B   modes=(none)
    card1-HDMI-A-2   status=disconnected   edid=0B   modes=(none)

`edid=0B` is the signal to read. EDID is the identification block every powered display returns over
dedicated pins. Zero bytes on BOTH ports means nothing is electrically presenting itself -- the Pi
is not rejecting a monitor, it cannot see one. No software setting produces that state.

Started 2026-09-13 12:23, eleven minutes after an unexplained reboot at 12:12. The tile watchdog
logged `no responsive wayland display` every five minutes for eight days -- 835 entries, ~275/day --
and nothing acted on any of them. Same silent-failure shape as the nine-day Frigate outage.

## What was ruled out, and how

- **Reseating both ends.** A 180 s watcher sampling both connectors every second recorded exactly one
  line, the initial reading, and no change across the reseat. Contact would have registered in ~1 s.
- **A software regression.** Suspected, because the failure began right after a reboot and because
  both ports failing IDENTICALLY looks far more like one driver fault than two hardware faults. But
  `apt` history is empty since 2026-08-19, kernel images date from Jun 17 and firmware from May 21.
  Nothing changed between working and broken. Do not reinstall or roll back anything.
- **Port choice.** Both ports, equally silent. Both HDMI controllers bound normally at boot and a
  forced re-probe (`echo detect > .../status`) behaved correctly.
- **The monitor.** A second TV on the same cable also showed nothing ("weak or no signal").
- **Hotplug detection alone.** HDMI carries picture data on one set of wires and presence on a single
  separate pin; a broken detect pin blinds the Pi while the picture path still works. Tested by
  forcing both outputs on regardless of detection:

      video=HDMI-A-1:1920x1080@60D video=HDMI-A-2:1920x1080@60D

  This WORKED at the driver level -- both connectors went `connected`/`enabled`, cage created two
  1080p outputs, and `grim` captured a 3840x1080 frame, so the Pi was really transmitting on both
  ports. The TV still showed nothing. So the fault is not confined to the detect pin; no picture
  signal is arriving either.

## Conclusion

Two displays, two ports, a fresh boot with the display attached, and a forced transmitting output all
produce nothing. The cable is the one component common to every failed test. A new cable is ordered
(2026-09-21). If it does not fix it, the remaining suspect is the Pi's HDMI output stage, which fits
the timeline -- this began immediately after the unexplained 2026-09-13 reboot.

## The forced mode was REVERTED, deliberately

`cmdline.txt` is back to stock (backup kept at `/boot/firmware/cmdline.txt.bak-before-forcehdmi`).
Leaving `1920x1080` forced would pin the wall to 1080p, and `wall-tiles.conf` OSD clock regions are
calibrated for **2560x1440**. That exact mistake has already cost a debugging session once: after the
monitor swap, stale 3840x2160 coordinates put 4 of 5 regions off-screen, they were silently skipped,
and the watchdog was left monitoring a single tile while appearing healthy.

If the new cable still does not assert detection, re-apply at the NATIVE resolution, not 1080p:

    video=HDMI-A-1:2560x1440@60D

That is also worth considering as a permanent hardening even if detection works, since it makes the
wall survive the monitor being switched off -- but only with the native mode.

## Still open

Nothing alerts on a missing display. The tile watchdog explicitly defers this case to
mailbox-watchdog, which only checks the VideoCore firmware mailbox; the mailbox was healthy, so it
did nothing, eight days running. Whichever watchdog takes it, "no wl_output for N minutes" should
reach a human -- the notify path (`script.announce`) already exists.
