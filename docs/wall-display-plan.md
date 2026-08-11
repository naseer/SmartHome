# Wall display — 27" kiosk on a Raspberry Pi 4

Written 2026-08-11. Status: **PLANNED, not started.** Decisions below are the user's, made 2026-08-11.

Goal: an always-on 27" display driven by a spare Raspberry Pi 4 Model B, showing Home Assistant,
with a **physical button** to switch between views: camera grid, single camera, a status dashboard
(sensors/switches), and a family calendar.

---

## 1. The constraint that shapes everything

**Do NOT build the camera views on Frigate's own Live grid.** Measured 2026-08-11 (OPEN-THREADS
thread 9): with that grid open, the Orin went from 26-28% CPU to **82-86%**, `det_fps` fell 40 -> 10,
and every camera dropped **100+ fps before reaching the detector**, with the GPU idle at 19%.

The cause is not video. The grid polls `GET /api/<cam>/latest.webp` about **once per second per
camera** — 199 requests in ~30 s — and each one is a resize plus a WebP encode in Frigate's main
process. Six a second is the load.

On a display that is open occasionally that is an annoyance. On one that is **on 24/7 it would
permanently degrade detection**, which defeats the point of the cameras. This is the single most
important thing to get right.

**Instead: stream from go2rtc over WebRTC/MSE.** The `_sub` streams are already H.264, and go2rtc is
already pulling them for detection, so serving one more consumer is packet forwarding — no decode,
no encode, no WebP. A host candidate was added 2026-08-11 (`go2rtc.webrtc.candidates:
192.168.50.200:8555` ahead of `stun:8555`) precisely so LAN clients can establish WebRTC; without a
host candidate a STUN-only config cannot help a client on the same network.

**NVENC is irrelevant here** and was explicitly considered. NVENC encodes video; the cost was WebP
encoding of stills in Python. Different code path entirely.

## 2. Hardware

| | |
|---|---|
| Display | 27" (already owned) |
| Compute | **Raspberry Pi 4 Model B** (already owned, unused) |
| Button | **Zigbee** — NOT yet owned, needs purchase |

**The Pi 4 is the RIGHT choice and this is counterintuitive — do not "upgrade" to a Pi 5.** The Pi 4
has a hardware H.264 decoder; **the Pi 5 does not** (Broadcom removed it). For a wall of H.264
camera streams the older board is the better one. If someone later swaps in a Pi 5 "to make it
faster", multi-camera video will get worse, not better.

Chromium on Pi OS does not always use the hardware decoder by default — it needs to be enabled and
then VERIFIED (`chrome://media-internals`, or watch CPU while a stream plays). Do not assume.

**Zigbee button, not USB/Bluetooth**, decided 2026-08-11. The house already runs Z2M on an SLZB-06,
so a press arrives in HA as an event with no software on the Pi at all — no HID key mapping, no BT
pairing to drop. A button with multi-press/hold gives several actions from one device.
No spare button exists today (current Z2M devices: 4 smart plugs, garage relay, garage tilt sensor).

## 3. How the button changes the view — prefer NO extra software

The obvious approach is `browser_mod` to navigate the browser remotely. **Avoid it if possible:**
there is no HACS on this HA instance, so it would be another hand-installed custom integration on
the box that runs the house (see the `hass_web_proxy` experience, 2026-08-11 — installed, patched,
and ultimately unused).

**Preferred: one view, conditional cards, driven by an `input_select`.**

- `input_select.wall_display` with options: `Cameras`, `Camera Single`, `Status`, `Calendar`
- The Zigbee button's press events drive an automation that cycles / sets that input_select
- The dashboard is ONE view containing `type: conditional` cards keyed off its state

No custom integration, no Pi-side software, no browser navigation. The Pi just sits on one URL.

**MUST VERIFY before committing to this:** that a `conditional` card whose condition is false does
NOT render its child, and therefore does not keep a camera stream running in the background. If
hidden cards still stream, this design silently costs the same as showing everything at once and the
whole point is lost. Test with one camera and watch the Orin's CPU.

Fallback if that fails: `browser_mod`, accepting the manual install.

## 4. Views

1. **Camera grid** — `advanced-camera-card`, `live_provider: go2rtc`, `modes: [webrtc, mse]`,
   `stream: <camera>_sub`. Never Frigate's Live grid.
2. **Single camera** — same card, one camera, larger. Cheapest camera view; a good default.
3. **Status** — sensors/switches. Cost is negligible next to video.
4. **Family calendar** — **BLOCKED: there are zero `calendar.*` entities in HA today.** A calendar
   integration has to be set up first (Google Calendar, CalDAV, or HA's built-in Local Calendar).
   Decide which before building this view.

**Idle behaviour: stay on one default view** (decided 2026-08-11) — not rotation, which would keep
every view's cost running continuously, and not screen-sleep. Pick the default deliberately: a
single camera or the status view costs far less than the grid.

## 4b. MEASURED 2026-08-11 — one camera is free, six is not

Built the dashboard at `/wall-display` and measured the Orin with it open.

| | container CPU | det_fps | detector util | skipped_fps |
|---|---|---|---|---|
| idle | 26-28% | 25-28 | ~45% | none |
| **1 camera streaming** | **24-26%** | 17-18 | 35% | **none** |
| 6-camera grid | 82-87% | 10-13 | ~20% | **100+ on every camera** |

**A single streaming camera is indistinguishable from idle.** The six-camera grid starves detection
just as Frigate's own Live grid did.

**So the always-on default MUST be a single camera**, not the grid. The grid can exist as a
button-selectable view used briefly — the cost is only unacceptable when it runs 24/7.

### What did NOT work, and why

- **Assuming `advanced-camera-card` avoids the polling.** It does not. With MSE streaming it ALSO
  issued 130 `latest.webp` + 41 `latest.jpg` requests in ~30 s. Using the card instead of Frigate's
  grid changes nothing on its own.
- **`image.refresh_seconds: 0`** to stop that polling. It removes the camera image entirely, so the
  card falls back to its embedded placeholder — a flower photo — and looked broken. Do not use 0.
- **Six simultaneous go2rtc streams through the proxy chain.** The browser reaches go2rtc via HA ->
  Frigate -> go2rtc, and at six streams it reconnected every few seconds (a spinner on each tile).
  **One camera over MSE is stable.** Whether the limit is 2, 3 or 4 was not tested.

### Still to test before mounting

- How many simultaneous streams stay stable — 2? 3? That sets the maximum useful grid.
- Whether `webrtc` is more stable than `mse` here; the stable single-camera test used MSE only.
- Whether HA's `conditional` cards unmount hidden children (section 3) — still the design's keystone.

## 5. Open questions

- Which calendar source? Nothing is configured yet.
- Which Zigbee button? Needs multi-press or hold to reach 4 views from one device.
- Does the grid need all six cameras at once, or is 4 enough? Every stream is a real decode on the Pi.
- Screen brightness/blanking at night — not decided; "stay on one view" was about view switching,
  not whether the panel dims.
- Does HA's `conditional` card actually unmount hidden children? Section 3 depends on it.

## 6. Measure it, do not assume

Before mounting anything, run the wall display for 10+ minutes and sample the Orin exactly as
thread 9 did: container CPU, `det_fps`, `skipped_fps`, detector utilisation. The target is that an
always-on display is **indistinguishable from idle** — 26-28% CPU, no skipped frames. Anything that
starves detection is not acceptable on a security system, however good it looks on the wall.
