# Frigate → Jetson AGX Orin migration plan

Written 2026-08-04. Status: **PLANNED, not started.** The Orin is owned and NOT YET FLASHED.

High-level status lives in `../AGENTS.md`; the camera/detector threads that led here are in
`../masn-stack/OPEN-THREADS.md`. This file is the migration itself.

---

## 1. Why — and what this reverses

The HD 630 ran out of room. Frigate's detector and every camera's VAAPI decode share one iGPU, and
after the ssdlite → YOLO-NAS swap (2026-08-04) that GPU sat pinned at its 1150 MHz maximum
continuously, so video playback queued behind inference and the UI crawled. Detection rate had to be
cut from 5 to 3 fps just to give decode room to breathe. **Vehicle detection — the entire reason for
the better model — is still off**, because there is nowhere to put it.

This is precisely the escape hatch the plan anticipated. `home-server-smart-home-plan.md` line 987
names the relief valve as offloading to the AGX Orin, with the measured trigger *">~25ms =
saturating"*. We are at 28–31 ms. The premise held; the hatch is being used as designed.

**But be explicit that this reverses a recorded principle.** Plan line 1007 says object detection is
*"MUST-NEVER-BE-DOWN: masn HD 630 … NOT the Orin-first — security detection has to be 24/7 on the
always-on box"*, and line 988 warns it *"couples security to the Orin"*. After this migration **the
Orin becomes must-never-be-down.** That is the real cost of this change, and it drives two decisions
below: the stable-software path in §2, and keeping masn able to take Frigate back in §7.

Not in scope: recordings still go to the same NAS over the same 1GbE. That was measured and is not a
bottleneck (64 MB/s reads, metadata fast). Migrating does not change it.

## 2. Software versions — flash JetPack 6.2.2, NOT 7.2

**JetPack 6.2.2** — Jetson Linux (L4T) 36.5, Ubuntu 22.04, kernel 5.15, CUDA 12.6, TensorRT 10.3.
Frigate image: **`ghcr.io/blakeblackshear/frigate:0.17.2-tensorrt-jp6`** (verified present on ghcr,
`linux/arm64`; pin the version rather than `stable-tensorrt-jp6` so a surprise upgrade cannot
happen unattended).

JetPack 7.2 (L4T r39.2, CUDA 13) is newer and does support AGX Orin, but **Frigate publishes no jp7
image** — `stable-tensorrt-jp7` and `0.18.0-tensorrt-jp7` are both 404, and Frigate 0.18 has no
stable release at all (beta only). The blocker is that `onnxruntime-gpu` has no prebuilt wheels for
Jetson under JP 7.2; the working community build (`ghcr.io/grossimd/frigate:0.18.0-beta2-tensorrt-jp7`,
discussion #23388) self-compiles onnxruntime 1.23 for sm_87. Upstream's position: *"Jetpack is
community supported build."*

So the 7.2 path means a **beta release from one individual's personal registry** on the box that just
became must-never-be-down, plus a known non-reboot-safe CDI GPU-passthrough gotcha (workaround:
drop the primary `/dev/dri/card*` nodes, keep `renderD*`). What it buys — Super Mode 200→241 TOPS,
newer CUDA — is irrelevant here: with no LLM sharing the Orin, JetPack 6.2.2 is already enormous
overkill for six cameras. Revisit when official jp7 support lands; JetPack 6→7 is a reflash, so
starting on 6.2.2 is not a dead end.

## 3. Phase 0 — flash the Orin

Host: **masn can be the flash host.** SDK Manager supports Ubuntu 24.04 x86_64, needs ~27 GB host +
16 GB target free (masn has ~69 GB). It is headless, so use `sdkmanager --cli`. Requires an NVIDIA
developer account.

**The cabling gotcha:** the AGX Orin devkit has two USB-C ports and they are not interchangeable.
- **Power** = the USB-C port *above the DC jack*.
- **Flashing to the host** = USB-C port *next to the 40-pin connector*.

Steps:

1. Install SDK Manager on masn (`.deb` from developer.nvidia.com).
2. **Force Recovery Mode**: hold the *middle* Force Recovery button while inserting the USB-C power
   plug. It powers on directly into recovery.
3. Connect the flashing USB-C port to masn. Confirm detection: `lsusb | grep -i nvidia`, and
   `sdkmanager --cli --list-connected`.
4. Flash, **targeting NVMe rather than the 64 GB eMMC** — Frigate's model cache, DB and logs all want
   the faster, larger device:
   ```
   sdkmanager --cli --action install --login-type devzone \
     --product Jetson --version 6.2.2 --target-os Linux \
     --host --target JETSON_AGX_ORIN_TARGETS --flash \
     --licenses accept --exit-on-finish
   ```
   Interactive `sdkmanager --cli` walks the same choices (OEM config, storage device) if the flags
   drift between releases — prefer it the first time.
5. First boot runs Ubuntu OEM setup (username/password). A monitor + keyboard on the Orin is the
   simplest path; SDK Manager can otherwise pre-seed the credentials.
6. Post-flash: set a static IP or DHCP reservation, enable SSH, add it to `~/.ssh/config` as `orin`,
   set `nvpmodel` to the max power mode and run `jetson_clocks`.

Verify before going further: `docker run --rm ghcr.io/blakeblackshear/frigate:0.17.2-tensorrt-jp6
python3 -c "import onnxruntime; print(onnxruntime.get_available_providers())"` should list
`TensorrtExecutionProvider`. If it does not, stop — nothing downstream will work.

## 4. Phase 1 — un-couple masn (do this BEFORE moving anything)

Three things currently assume Frigate is on localhost. All are in git.
**(a) and (d) are DONE (2026-08-04); (b) and (c) wait for the Orin to have an address.**

**(a) mosquitto is localhost-only.** — **DONE.** It now publishes **two explicit bindings**:
`127.0.0.1:1883` (so host-mode HA keeps working with its config entry untouched) and
`${MASN_LAN_IP}:1883` for the cross-box Frigate. Deliberately *not* `0.0.0.0`, which would also
expose it on the tailnet. `MASN_LAN_IP` is a new `.env` key (documented in `.env.example`).
Verified: both listeners present, all three clients (HA, Z2M, Frigate) reconnected, and a remote
client authenticated against the LAN IP successfully.

**(b) Frigate's `:5000` is localhost-only AND unauthenticated.** `docker-compose.yml:92` binds
`127.0.0.1:5000:5000`. `homeassistant/packages/person_notifications.yaml:14` calls
`http://127.0.0.1:5000/api/events/{{ event_id }}` — that is the vehicle directness-gate fetch. Once
Frigate is on the Orin this must point at the Orin. **Do not simply expose `:5000` to the LAN**: it is
the unauthenticated API. Prefer the authenticated `:8971` with a token, or firewall `:5000` to masn's
IP only.

**(c) The HA Frigate integration** points at the Frigate URL — update to the Orin's address.

**(d) Rotate the MQTT password.** — **DONE**, alongside (a): moving the broker from loopback-only to
LAN-reachable is exactly the moment the deferred "later" stopped being acceptable.

Consumers pick the credential up three different ways, which is the part worth remembering:
Frigate and Z2M read `${MQTT_PASSWORD}` from `/opt/stack/.env` (restart suffices), but **Home
Assistant stores it in a UI config entry** at `.storage/core.config_entries` — root-owned, and HA
rewrites that file on shutdown, so it must be edited with HA STOPPED (do it from a throwaway
container; masn's `.storage` is not writable by the login user). Backups of the passwd file, `.env`
and `core.config_entries` were taken first.

Verified after: old credential REJECTED, all three clients reconnected, HA at 661 entities with the
MQTT-backed `cover.garage_door` still reporting, unavailable-entity count unchanged at 134 (all
vehicle entities, expected while vehicles are off).

Future improvement, not done: split the single shared `mqtt` user into per-service accounts
(`ha`/`z2m`/`frigate`), matching the per-share least-privilege pattern already used for the NAS. That
would let the Orin's credential be revoked independently of the house.

## 5. Phase 2 — Frigate on the Orin, in shadow

Run both instances simultaneously before cutting over. The cameras can serve multiple RTSP clients;
this costs nothing but bandwidth and buys a real comparison.

1. Docker + nvidia-container-runtime come with JetPack; verify `docker info | grep -i runtime`.
2. Recreate the NAS mount. The `frigate_media` cifs **volume** definition (`docker-compose.yml:131-136`)
   ports across unchanged — same `NAS_IP`, `NAS_FRIGATE_SHARE`, and least-privilege `frigate` creds.
   Keep the hardening property: if the NAS is unreachable Docker refuses to start Frigate rather than
   silently filling local disk.
   **Point the shadow instance at a different subdirectory** so it cannot write over masn's recordings
   while both run.
3. Copy `frigate/config/` across. Change only the detector block; leave cameras, zones, masks and
   `min_area` alone so the comparison is honest.
4. Do **not** copy `frigate.db` yet (228 MB) — the shadow run should start clean. It moves at cutover.
5. Model: the existing **`yolo_nas_s.onnx` (47 MB) carries over** — the jp6 image auto-detects Jetson
   and runs ONNX via the TensorRT execution provider, and `yolonas` is supported. `tools/export-yolonas.sh`
   is not wasted work. Expect the first start to be slow while TensorRT builds its engine cache.
6. Compare with `masn-stack/tools/frigate-detector-stats.sh` (works against any host via `FRIGATE_API`).
   Baselines to beat, from masn today: 28–31 ms inference, 16.5 det/s offered at 3 fps, 23% per-process
   utilisation across two detector processes.

## 6. Phase 3 — cutover, and Phase 4 — spend the headroom

Cutover: stop Frigate on masn → move `frigate.db` → repoint the shadow instance at the real recordings
path → update HA (integration URL + the `rest_command` from Phase 1b) → confirm person alerts still
fire end-to-end → leave masn's Frigate service defined but stopped for a week.

Then spend what the Orin bought, **one change at a time, measuring between each** — the mistake to
avoid is changing four things and not knowing which one cost what:

1. **Detect fps back to 5** (undo the 2026-08-04 emergency cut).
2. **Re-enable vehicles** — `objects.track: [person, car, bus, motorcycle]`. Safe: the notification
   automation `automation.frigate_moving_vehicle` is `off`, so this generates events for evaluation
   without sending pushes. **This is the actual goal of the whole exercise** — it finally answers
   whether a stronger detector fixes the parked-car box flicker, which has never been tested.
3. **A bigger model / higher resolution** — YOLO-NAS at 640 rather than 320, or RF-DETR, which
   OpenVINO refused on the HD 630 (needs Xe/Arc) but is available on CUDA.
4. Reconsider `min_area: 0.005` and the detect-fps-driven tuning; some of it was compensation for a
   starved GPU and may no longer be needed.

## 7. Rollback

Keep masn able to take Frigate back for at least a week: leave its compose service defined (stopped),
leave `yolo_nas_s.onnx` in place, and do not delete `/opt/stack/frigate/config`. Reverting is: start
masn's Frigate, point HA back at `127.0.0.1`, re-bind mosquitto to loopback. The config in git at tag
`eef43e1`/`988319d` is the known-good HD 630 state.

Given the Orin becomes must-never-be-down, also decide: what happens on an Orin failure? Today masn is
the answer. Do not let that quietly stop being true.

## 8. Open questions

- **Does the migration actually fix the parked-car flicker?** Still unanswered. It is the reason for
  all of this, and Phase 4.2 is the first time it gets tested.
- **NVDEC for decode.** The Orin should decode camera streams on dedicated NVDEC silicon rather than
  the GPU — that separation is the whole architectural point. Verify Frigate is configured to use it
  (`h264_nvv4l2dec` / the jetson ffmpeg preset) rather than falling back to CPU decode.
- **DLA.** Moot while the Orin is Frigate-only. If an LLM node ever lands there, revisit: DLA pinning
  appears to require the legacy TensorRT detector with older YOLOv4/v7 models, so "modern model + DLA
  placement" is unconfirmed and would need checking before the Orin is shared.
- **Power/thermals/siting** — the Orin becomes always-on infrastructure; where it lives, and on what
  UPS, is unaddressed.
- **The VOD 503 bug is independent of all this** and travels with you. `front_door` intermittently
  writes 2-second segments instead of 10-second (hour 12 today: 1592 segments vs a normal ~360),
  overflowing nginx-vod's durations array so a 1-hour playback request returns HTTP 503. Moving
  hardware will not fix it.
