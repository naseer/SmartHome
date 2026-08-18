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

### ROOT CAUSE, profiled 2026-08-11 — Frigate's own UI polls; the HA card streams

Measured per-process with `orin-stack/tools/cpu-profile.sh` (differences /proc utime+stime over a
fixed window -- `ps pcpu` reports LIFETIME averages and is useless for this).

| | container cores | vs idle |
|---|---|---|
| true idle (verified: no extra go2rtc consumers) | **2.7** | — |
| **HA card, 1 camera, `live_provider: go2rtc` (MSE)** | **2.8** | **+0.1 — free** |
| Frigate's own UI, 1 camera | 5.1 | +2.4 |
| Frigate's own UI, 6-camera grid | 8.7 | +6.0 |

**Frigate's Live UI polls `latest.webp` + `latest.jpg` several times a second PER VISIBLE CAMERA,
on top of streaming.** Measured with ONE camera open: 72 webp + 41 jpg + 9 MSE websockets in a
~200-line log window. Each poll reaches back into that camera's `capture` -> `process` pipeline to
pull, resize and encode a frame. With one camera open that chain went from ~31% to **221%**:

```
frigate.process:driveway   22.4% -> 88.3%
frigate.capture:driveway  (absent) -> 77.8%
that camera's ffmpeg         8.9% -> 55.3%
detectors                   20.0% -> 8.9%   (starved)
```

At the 6-camera grid the same cost lands everywhere at once -- the API process hit 105%, and
`recording_manager` and `review_segment_manager` woke up too (37-45%), because the UI also polls
`/api/events`, `/api/<cam>/recordings`, `/api/<cam>/ptz/info` and `/api/config` continuously. It was
never just WebP encoding; that was one visible piece of a broad polling surface.

**The HA card avoids nearly all of it** because go2rtc simply forwards packets it is already
receiving for detection. **~24x cheaper for the same single camera.**

### CORRECTION — the six-camera grid IS free. The variable was WEBRTC, not camera count.

Re-measured with the HA card at six cameras, **MSE only**:

| | container cores | detection |
|---|---|---|
| true idle | 2.7 | — |
| HA card, 1 camera (MSE) | 2.8 | healthy |
| **HA card, 6-camera GRID (MSE only)** | **2.6** | **no skipping, det_fps 18-21, util 37-45%** |
| HA card, 6-camera grid (`[webrtc, mse]`) | ~8+ | 100+ fps skipped, spinners on every tile |
| Frigate's own UI, 6-camera grid | 8.7 | starved |

**Six streams cost nothing.** The earlier "the grid starves detection" conclusion was WRONG for the
HA card -- it was true only because that config listed `webrtc` first. WebRTC never established
reliably, so it churned (connect -> fail -> retry, six times over), and THAT was the 82-87% CPU and
the reconnecting spinners. Removing `webrtc` from `modes` fixed both at once.

**`modes: ["mse"]` -- do NOT add `webrtc` back** without re-measuring. The host candidate added
earlier (`192.168.50.200:8555`) did not make it reliable here.

**CONCLUSION FOR THE WALL DISPLAY: HA card, `live_provider: go2rtc`, `modes: ["mse"]`, `_sub`
streams. A six-camera grid at `grid_columns: 3` is free.** Do NOT point the kiosk at Frigate's own
Live page -- that one polls regardless of camera count and costs +2.4 cores for a SINGLE camera.

MEASUREMENT DISCIPLINE, learned the hard way here: the first "idle" baseline was taken with the HA
card still open in a forgotten tab. It read 2.8 cores against a true idle of 2.7 -- harmless by luck,
because that path is free, but it could equally have hidden a large cost. **Verify idle by checking
go2rtc consumers (`/api/streams`: 1 per stream = Frigate only) before trusting a baseline.**

### Still to test before mounting

- How many simultaneous streams stay stable — 2? 3? That sets the maximum useful grid.
- Whether `webrtc` is more stable than `mse` here; the stable single-camera test used MSE only.
- Whether HA's `conditional` cards unmount hidden children (section 3) — still the design's keystone.

## 4c. Pi build — OS, kiosk, and audio (decided 2026-08-12)

**Order of work, per the user: AUDIO FIRST.** Announcements are independently useful and testable,
and depend on none of the kiosk decisions. Wake word is explicitly DEFERRED.

### OS: Raspberry Pi OS Lite (64-bit) + `cage`

**Lite, not Desktop** — ships with no GUI at all, so there is no desktop to land on accidentally.

**`cage`** is the kiosk layer: a Wayland compositor that runs EXACTLY ONE fullscreen application.
No window manager, no taskbar, no alt-tab, nothing behind the browser. If Chromium exits, cage exits
and systemd restarts it. That is a much stronger guarantee than "Desktop with the panel hidden",
where a stray tap can still surface a menu — which is what the user explicitly asked to avoid.

Alternatives considered: **DietPi** (lighter, has a kiosk preset, but another distro to learn) and
**FullPageOS** (purpose-built, works on day one, less current base). Pi OS Lite + cage chosen for
longevity on a box that will sit on a wall for years.

**MUST VERIFY: that Chromium actually uses the Pi 4's hardware H.264 decoder.** It does not always
by default. Check `chrome://media-internals` and watch CPU while a stream plays. This decides
whether six streams are watchable — and remember the Pi 4 was chosen over a Pi 5 precisely because
the Pi 5 has no H.264 decoder at all.

### Audio: ALSA + `gmediarender`

Lite has no PulseAudio/PipeWire, which is fine. **`gmediarender`** is a small DLNA renderer that
plays to ALSA; HA auto-discovers it as a `media_player`, so `tts.speak` and `media_player.play_media`
work with no custom integration and no HACS.

First milestone, in order:
1. Flash Pi OS Lite 64-bit
2. Choose the audio output (USB speakerphone / HDMI / 3.5 mm) and set the ALSA default
3. Install `gmediarender`
4. Confirm it appears in HA as a `media_player`
5. Send it a test TTS

Nothing about kiosk or voice needs to exist for that to be useful.

### Hardware to order

- **4-button Zigbee remote** — NOT a single button. Four views means one press per view; multi-press
  on one button is unusable by anyone but the person who configured it. Candidates: IKEA STYRBAR,
  Philips Hue Dimmer v2 (both wall-mountable next to a screen), or an Aqara double rocker
  (ecosystem-consistent with the U200 lock and garage relay). **Check Z2M's supported-devices list
  before ordering** — model variants matter.
- **Small powered speaker** (decided 2026-08-12, in preference to a USB speakerphone). Cheaper and
  tidier on a wall, and it avoids committing to a microphone form factor before it is known how
  voice will actually be used. **Consequence: voice will need a SEPARATE microphone later** — the
  one-device shortcut is given up deliberately.
  - Prefer a speaker that is a **USB audio device** over one on the 3.5 mm jack. The Pi 4's analog
    output is adequate for chimes and TTS but is noisy; many cheap "USB speakers" are USB audio
    devices and sidestep it for the same money.
  - **GOTCHA: with a monitor on HDMI the Pi defaults audio to HDMI.** If the 27" has no speakers or
    poor ones the result is silence, which reads as "the setup failed". Set the ALSA default output
    explicitly to the analog jack or the USB device.

### Voice, when it comes (deferred)

Maps onto the existing intent in `../AGENTS.md`: Orin = brains (Whisper/Piper/Ollama via Wyoming),
Pi = satellite (mic in, speaker out) alongside the kiosk. The Orin has ~9.5 spare cores and ~50 GB
unused RAM as of 2026-08-11.

**The risk to measure, not assume:** the Pi 4 would run Chromium with six video streams AND
continuous wake-word detection at once. That may be fine or it may be what makes the display
stutter. If it is too much, HA Voice Preview Edition is a purpose-built satellite that takes voice
off the Pi entirely.

## 4d. BUILT 2026-08-17 — kiosk running, and the buffering was the cameras

**Working:** Pi 4 on WiFi (`humans`, 192.168.50.76), Pi OS Lite + `cage` + Chromium 151 in kiosk
mode via `wallpi-stack/kiosk.service`. HA dashboard `/wall-display`, logged in as a **non-admin,
local-only** `WallPi` user. `kiosk-mode` (a single JS file in `config/www/`, registered as a Lovelace
resource -- no HACS) hides the sidebar and header on that dashboard only.

**HARDWARE DECODE CONFIRMED** -- the reason the Pi 4 was chosen over a Pi 5:
```
/dev/video10 held by chromium      <- the Pi's H.264 decoder
~38% of 4 cores, 61.8% idle, 61.8 C, throttled=0x0
```

**THE BUFFERING WAS THE CAMERAS, NOT THE PI OR WIFI.** Streams stalled and tile timestamps drifted
up to 6 s apart. Cause: keyframe interval.

```
before:  driveway/backyard 1 keyframe per 60 frames;  gates/front_door 1 per 30
after:   1 per 13 frames (~1/second)
```

MSE can only START and only RECOVER FROM LOSS on a keyframe, so a 4-second GOP means every hiccup
freezes a tile for seconds. This very likely also explains why `[webrtc, mse]` churned on
2026-08-11 -- WebRTC also needs a keyframe to begin, so setup kept timing out and retrying.

**Fixed via the Reolink HTTP API, not the app.** The app and web UI do not expose I-frame interval.
```
subStream before: {"gop": 4, "frameRate": 15, "size": "896*512", "bitRate": 1024}
subStream after:  {"gop": 1, ...}    # gop is in SECONDS
```

**THE API IS HTTPS-ONLY.** Every earlier attempt (2026-08-10) used http and failed with an
unparseable response; http returns 302 to https. That one detail blocked camera automation for a
week. Login: `POST https://<ip>/cgi-bin/api.cgi?cmd=Login` with
`[{"cmd":"Login","action":0,"param":{"User":{"Version":"0","userName":"admin","password":"..."}}}]`,
then `GetEnc` / `SetEnc` with the token. Read the current subStream and change ONLY `gop` -- do not
invent values.

### Card settings that mattered

- `live.show_image_during_load: false` -- this fetches a still per camera while a stream starts, and
  is what produced the "bunch of videos buffering" look. It is ALSO the source of the latest.jpg /
  latest.webp polling chased on 2026-08-11.
- `dimensions.aspect_ratio_mode: dynamic` -- a forced 16:9 left white gaps, because the sub-streams
  are 1.75, 1.33, 1.78 and 2.67 wide.
- `driveway_tele` dropped: it is the TrackMix's second lens, duplicating `driveway`.
- `go2rtc.modes: ["mse"]` only -- see the webrtc note above.

### Still open

- Audio: `gmediarender` runs and HA has `media_player.wall_display`, but NO audio has been proven to
  reach ALSA. Waiting on the powered speaker; the monitor may have no speakers at all.
- The Zigbee button and the input_select view switching.
- Whether conditional cards unmount hidden children (still the keystone of the button design).

## 4e. Filling the empty cell -- what does NOT work

The wall has one empty cell (column 3, row 2). advanced-camera-card lays its 5 cameras out as a
3-column MASONRY with driveway spanning two columns; column 3 (front_door + west_gate) is shorter
than columns 1-2, and the leftover is the gap. A card cannot place anything in its own empty cell,
so filling it means placing the tiles by hand instead of letting the card self-arrange.

Two approaches were tried on 2026-08-17 and BOTH FAILED. Do not retry them:

**1. HA `sections` view with `grid_options`.** Sections look ideal -- a 12-column grid with per-card
column and row spans, which maps exactly onto the layout. But SECTIONS CAP THEIR OWN WIDTH. With
`max_columns: 1` the whole wall collapsed into a ~500px column in the middle of a 4K screen.
Sections are built for readable dashboards, not full-bleed walls. A `panel` view (exactly one card,
stretched full-bleed) is the only view type that fills the screen -- which is what the wall uses.

**2. `--force-device-scale-factor=2`** to get a 1920x1080 CSS viewport for legible text. Under
Wayland/cage the page rendered 1:1 in the TOP-LEFT QUARTER of the screen instead of scaling up; the
flag does not negotiate with the compositor's surface scale. If UI text ever needs to be bigger,
use Chromium page zoom or cage's output scale instead.

### What would actually work

The card must be a real layout engine. Native HA has none that does non-equal columns full-bleed:
`horizontal-stack` splits evenly, the classic `grid` card has no column spans, and
`picture-elements` has no element type for arbitrary cards.

`custom:layout-card` (grid-layout) does exactly this via `grid-template-areas`, and can be
side-loaded the same way `kiosk-mode.js` was -- drop the .js in `config/www/` and register a
Lovelace resource, no HACS. That is the path if the weather/notification panel is wanted.

Useful card options confirmed while investigating, for whenever this is built:
- `live.layout.fit: contain | cover | fill` (per card) and `cameras[].dimensions.layout.fit`
  (per camera) -- `cover` fills a tile by cropping, which is how you get seamless tile edges.
- `dimensions.aspect_ratio_mode: unconstrained` + `dimensions.height: "100%"` makes a card fill the
  cell it is given rather than imposing the stream's aspect ratio.
- backyard is 1536x576 (2.67:1). `cover` on that one crops away a third of the patio, so it wants
  `contain` even if every other tile uses `cover`.

### Iterating on the wall without a human

`wallpi-stack/tools/screenshot.sh` grabs cage's framebuffer with `grim` over SSH. A layout change
can be verified in seconds instead of asking someone to photograph the monitor.

## 4f. AUDIO PROVEN 2026-08-17 -- end to end, HA to ALSA

Audio had been "configured but never proven" since the Pi was built. It is now proven, and the
reason it looked dead is recorded here because it wasted weeks.

**HDMI audio was never broken -- it was being opened wrongly.** The vc4-hdmi PCM accepts EXACTLY
ONE format:

```
$ aplay -D hw:1,0 --dump-hw-params /dev/zero
FORMAT:  IEC958_SUBFRAME_LE          <- S/PDIF framing, nothing else
RATE:    [32000 48000]
```

Every player offering ordinary `S16_LE` to `hw:1,0` fails with "Sample format not available", which
reads as a dead device. **The fix is `plughw:` instead of `hw:`** -- the plug layer inserts the
IEC958 conversion. With that, the PCM reaches `state: RUNNING` immediately.

**The monitor accepts audio but cannot make sound.** Its ELD advertises the sink honestly:

```
/proc/asound/card1/eld#0:  monitor_name PG32UCDM
                           sad0_coding_type [0x1] LPCM, 2ch, 32000/44100/48000
```

The PG32UCDM has no built-in speakers, only a headphone jack. So HDMI audio was arriving at a
display with no transducer -- audio was working and inaudible at the same time. gmediarender was
pointed at exactly this sink (`ALSA_DEVICE="plughw:CARD=vc4hdmi0,DEV=0"`).

### Both sinks, verified

| sink | device | format | result |
|---|---|---|---|
| monitor over HDMI | `plughw:1,0` | `IEC958_SUBFRAME_LE` @ 48k | opens, RUNNING, clean close |
| Pi 3.5mm jack | `plughw:0,0` | `S16_LE` @ 48k | opens, RUNNING, clean close |

**Card 0 (the Pi's own jack) is now the default**, via `wallpi-stack/asound.conf`, and gmediarender
points at it via `wallpi-stack/gmediarender.default`. Announcements stay working if the monitor is
ever swapped.

### End-to-end proof

An HA `tts.speak` aimed at `media_player.wall_display` drove the PCM through
`closed -> OPEN -> RUNNING`. The chain HA -> DLNA -> gmediarender -> GStreamer -> ALSA is real.

**HEARD 2026-08-17.** Headphones into the Pi's 3.5mm jack; both a test tone and an HA TTS
announcement were audible. Audio is fully verified end to end -- no part of the chain is assumed.

### Volume: two stacked gains, which is what made this confusing

Sound was audible but quiet, and then the tone was fine while ANNOUNCEMENTS were still quiet. That
asymmetry is the tell: `speaker-test` writes straight to ALSA, while announcements pass through
gmediarender first, so only announcements saw the second attenuator.

```
ALSA mixer (card 0 'PCM')     applies to EVERYTHING
gmediarender INITIAL_VOLUME_DB applies ONLY to what it plays  <- was -10
```

**The ALSA mixer is now the single volume control; gmediarender sits at unity (0 dB).** Two gains
that have to be reasoned about together is not worth the trouble.

BEWARE THE MIXER SCALE -- it is steeply logarithmic and the percentage badly misleads:

```
 60% = -38.56 dB      80% = -17.28 dB      90% = -6.64 dB      95% = -1.32 dB
```

60% is not "a bit quieter than 90%", it is 32 dB down -- near inaudible. Set it in dB, not percent.
Currently 95%, and **persisted with `sudo alsactl store`**, without which it resets to the driver
default on reboot.

The Pi 4's jack is PWM-driven and weak by design -- treat it as line level. A powered speaker
brings its own amplifier, which is where loudness should actually come from; these levels just
avoid throwing signal away first. If it sounds thin or hissy with a real speaker, a USB audio
dongle appears as another card and `asound.conf` moves to it in one line.

### Two traps to remember

- **`media_player.wall_display` goes `unavailable` whenever gmediarender restarts** and does NOT
  recover on its own -- HA caches the DLNA device URL. Reload the `dlna_dmr` config entry after any
  restart. It sat unavailable for exactly this reason.
- The entity was still named `raspberrypi Wall Display` from before the Pi was renamed; renamed to
  `Wall Display`.

## 4g. REBOOT TEST 2026-08-17 -- one hang in two power cycles

Run before relocating the Pi, on the principle that a wall-mounted display must survive losing
power unattended.

**Power cycle #1 FAILED.** The wall froze on the last frame it had decoded. The kernel and SSH
stayed fully responsive -- only anything touching the VideoCore firmware blocked, forever, in
uninterruptible sleep:

```
1056 D+  rpm_resume                chromium    <- blocked resuming the power-managed decoder
1326 D   rpi_firmware_property_li  vcgencmd    <- blocked on the firmware mailbox
1441 D   rpi_firmware_property_li  vcgencmd
```

**The VideoCore firmware mailbox was wedged.** Chromium could not get decoded frames, so the last
frame stayed on screen; `grim` hung too (it needs DRM); `vcgencmd` hung, which is the quickest
one-line test for this state. Load average hit 8 on 4 cores, but that was BLOCKED TASKS, NOT CPU --
memory was fine (2.2 GB free, zero swap) and there was no real CPU work. Do not read that load
figure as overload.

A second reboot came back completely clean, so the wedge is transient, not a permanent breakage.

**Power cycle #2 PASSED** -- kiosk active, hardware decode reacquired (/dev/video10 held), mailbox
answering, ALSA level still -1.32 dB (alsactl store held), gmediarender at unity,
`media_player.wall_display` back to `idle` on its own, same IP over WiFi. Verified live by diffing
two screenshots 6s apart: 20% of sampled cells changed, so the wall was genuinely moving.

### Why the obvious fix does not apply

A hardware watchdog (bcm2835_wdt + RuntimeWatchdogSec) will NOT catch this. The kernel never
stopped scheduling -- SSH, systemd and userspace were all healthy. Only the firmware mailbox was
dead. The watchdog would keep being petted while the screen stayed frozen.

What matches the observed failure is a health check that tests THE MAILBOX specifically:
`timeout 5 vcgencmd measure_temp`, and on repeated failure restart the kiosk, escalating to a
reboot. Not yet built.

### Before relocating

- DHCP reservation for 192.168.50.76. HA caches the DLNA device URL, so a new IP silently kills
  announcements until the config entry is reloaded.
- Re-measure WiFi after mounting. Currently 5 GHz (5560 MHz) at signal 67; 5 GHz degrades sharply
  through walls, and the streams will show it first.

## 4h. WATCHDOGS BUILT 2026-08-17 -- two faults, two recoveries

A wall display fails in a way no other machine does: IT KEEPS LOOKING FINE. A frozen wall and a
working wall are identical from across a room, so a fault can persist for hours. Two distinct
failures were observed and each got a watchdog. They are NOT redundant -- neither can see the
other's fault.

### mailbox-watchdog -- the whole wall freezes

The VideoCore firmware mailbox wedges (see 4g). Probes `timeout 5 vcgencmd measure_temp`, plus a
scan for processes stuck in D on `rpi_firmware*` / `rpm_resume`. Escalates: 3 consecutive failures
-> restart the kiosk; 6 -> reboot, with a 1 hour cooldown so a bad boot cannot become a reboot loop,
and a sysrq force-reboot if the clean reboot itself blocks on the same dead firmware.

Runs as root (it must be able to reboot). Every 2 minutes, starting 5 minutes after boot -- the
mailbox is legitimately busy while the GPU context comes up and probing into that gives a false
failure on EVERY boot.

### tile-watchdog -- ONE tile freezes

Observed after a reboot: backyard froze on a single frame while the other four played. go2rtc was
still receiving AND sending that stream (`recv 576.3 -> 578.0 MB` over 12s), so neither camera nor
server was at fault -- **the browser's MSE decoder stalled and never recovered**. Restarting the
kiosk cleared it. The mailbox probe cannot detect this: the firmware is perfectly healthy.

**Liveness is measured from the OSD CLOCK Reolink burns into every stream.** Two `grim` grabs of
just the clock region, 6 seconds apart, are byte-identical if and only if that stream is not
advancing. This defeats the obvious false positive: a genuinely still scene at 3am still has a
running clock, whereas a naive whole-tile pixel diff would call it frozen and restart the kiosk
every night. Grabbing a ~500x45 region rather than whole 4K frames also keeps it cheap on a Pi
already decoding five streams.

**It acts only when at least one tile is live AND at least one is frozen.** If EVERY tile is frozen
the fault is the display, the compositor or the network, and restarting the kiosk is the wrong
response -- possibly a looping one. Only a mixed picture proves the wall works and one stream is
stuck. 3 consecutive detections -> restart, 15 minute cooldown.

Runs as the kiosk user, since `grim` needs that user's wayland socket, and uses passwordless sudo
only for the restart. Every 5 minutes from 8 minutes after boot.

### Tested, not assumed

Both were installed in DRY_RUN and driven through their full escalation before being enabled:
counters increment, the action fires at the threshold, recovery clears the counter, and the
cooldown suppresses repeats. The tile detector was tested by adding the EMPTY WHITE CELL as a fake
tile -- a permanently static region -- which produced `STALLED: fake_frozen (live=5 frozen=1)`,
proving it distinguishes a stalled tile from five live ones. With the real config it stays silent.

### Maintenance trap

`/etc/wall-tiles.conf` regions are LAYOUT-DEPENDENT. Rearranging the dashboard moves the clocks, and
a stale region silently points at scenery -- reading as permanently frozen (restart loop, capped by
the cooldown) or permanently live (no detection at all). After any layout change, re-verify with
`wallpi-stack/tools/show-osd-regions.sh`, which crops the configured regions and labels them so you
can see whether each still lands on a timestamp. Reinstalling never overwrites a tuned config; it
drops the new one at `/etc/wall-tiles.conf.dist`.

## 4i. WHITESPACE GONE 2026-08-17 -- explicit 3x3 grid with an info panel

The empty cell is filled and the wall has NO whitespace anywhere.

```
drive drive front        driveway spans 2x2 = 2560x1440 = 1.78, vs its 1.75 stream:
drive drive west         the hero tile shows its full scene with no crop worth seeing
back  east  info
```

Built by `wallpi-stack/build-wall-dashboard.py`, pushed over the websocket API with
`tools/lovelace.py`. The dashboard lives in HA's database, so the SCRIPT is the source of truth --
keep changes there, not in the UI editor, or the next run silently reverts them.

### Two third-party cards, side-loaded like kiosk-mode (no HACS)

- `layout-card` v2.4.7 -> `custom:grid-layout`, the CSS `grid-template-areas` engine. Needed
  because advanced-camera-card's own grid is a MASONRY, which always leaves a ragged bottom, and no
  native HA card does full-bleed unequal columns (see 4e).
- `card-mod` v4.2.1 -> CSS into cards. Needed because the stock info cards render as a bright white
  block with ~8px text on a 4K panel: glaring beside five dark video tiles, and unreadable from
  across a room, which is the only distance this screen is ever viewed from.

Both pinned to a tag and fetched from the repo (neither publishes release assets), installed to
`/config/www/` and registered as Lovelace resources.

### Things that cost a round trip each

- **`fit` belongs to the CAMERA, not to `live`.** `live.layout.fit: cover` is accepted and does
  nothing; every tile stayed letterboxed. The video element's object-fit comes from
  `cameras[].dimensions.layout.fit`.
- **`1fr` is `minmax(auto, 1fr)`.** A child's min-content grew the driveway rows and squeezed the
  info row until the Humidity line fell off the bottom. `repeat(3, minmax(0, 1fr))` pins exact
  thirds.
- **Markdown renders into `ha-markdown`'s SHADOW DOM.** An `h1` rule at ha-card level never reaches
  it, so the clock stayed tiny. card-mod's `ha-markdown $:` syntax crosses the boundary.
- **A vertical-stack sizes each child to content**, leaving a white strip under the panel. Flex
  column plus `flex: 1` on the last child stretches it to the cell floor.

### front_door is deliberately `contain` while everything else is `cover`

`cover` on a 4:3 stream in a 16:9 cell crops top and bottom, which threw away its OSD CLOCK --
anchoring the crop to the top with `position: {y: 0}` did NOT bring it back either. That costs the
timestamp AND leaves tile-watchdog with no liveness signal for that tile. `contain` shows the whole
frame with modest side bars, and for a door camera keeps the full field of view. A deliberate trade:
bars on one tile, but every tile stays monitorable.

### Everything white is fixed by ONE THEME, not by card styling

There were TWO different whites, painted by two different things, which is why fixing them one at a
time kept half-working:

```
#ffffff   the camera card's own background -> pillarbox bars beside the 4:3 front_door
#fafafa   HA's page background             -> seams in the grid gaps
```

`card_mod` could not reach the first: advanced-camera-card barely uses `ha-card`, and neither
`--advanced-camera-card-background` nor the HA theme variables set on the grid container touched
it. Setting the VIEW background fixed the seams and the strip under the info panel but not the bars.

**The fix is a theme.** `ha-config/themes/wallpi-black.yaml` sets the surface variables at the root,
so everything downstream inherits regardless of which element paints it, and it is applied with
`theme: wallpi-black` ON THE VIEW -- so it affects only the wall, and the family's phones keep the
normal light theme. HA's config already had `frontend: themes: !include_dir_merge_named themes` with
no themes directory, so this needed no restart: create the directory, drop the file in, call
`frontend.reload_themes`.

Verified by sampling pixels rather than eyeballing a downscaled screenshot -- which is how the bars
were missed the first time round:

```
front_door bar (2600,400)   (0,0,0)
vertical seam (2560,900)    (0,0,0)
horizontal seam (900,1440)  (0,0,0)
```

An 8px grid gap also existed that was never asked for; `grid-gap` alone was ignored, so the layout
now sets `grid-gap`, `gap` and `--masonry-view-card-margin` together.

### front_door: pillarbox, deliberately

It is 640x480 (4:3) in a 16:9 cell and cannot both fill the cell and show its whole frame. `cover`
fills it but crops 120px off the top, taking the OSD CLOCK with it -- which blinds tile-watchdog to
that tile. `dimensions.layout.position` did NOT move the crop (`{"y": 0}` had no effect), so that
escape route does not exist. `contain` keeps the whole porch view and the clock; the bars it leaves
are black under the theme. While it was briefly on `cover`, it had to be REMOVED from
`/etc/wall-tiles.conf`: a region with no clock never changes, and tile-watchdog would have read it
as permanently frozen and restarted the kiosk every cooldown, forever. It is back in now.

### Card backgrounds are forced black

HA cards are WHITE in the light theme, so anything the video does not cover shows as a white bar --
most visibly the pillarbox either side of front_door, which is the one `contain` tile. card-mod
forces `ha-card` to black on every camera card, and drops the border, shadow and corner radius, so
the tiles butt together as one surface. Black reads as the frame of a video wall; white reads as a
missing tile.

### The info panel

Clock (markdown, `now()` re-renders every minute -- no sensor or automation needed), 5-day forecast,
then garage / front door lock / indoor temp / humidity. Dark translucent so it reads as part of the
wall rather than a floating card.

### THE TILE REGIONS MOVED

This layout change invalidated every region in `/etc/wall-tiles.conf` -- the exact trap recorded in
4h. New regions verified by cropping and LOOKING at them, not by assuming. Re-verify with
`wallpi-stack/tools/show-osd-regions.sh` after any future layout change.

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
