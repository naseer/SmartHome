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

**BLOCKED as of 2026-08-05: waiting on an NVMe.** See "What the board actually is" below. Everything
else in this section is ready to run the moment the drive is installed.

### Flash host — naahmed-linux, NOT masn (corrected 2026-08-05)

The original plan named masn as the flash host. It isn't: the Orin is physically cabled to
**naahmed-linux**, the workstation this repo lives on. That box runs **Kubuntu 26.04**, which is
outside SDK Manager's supported set (20.04 / 22.04 / 24.04) — but **SDK Manager installs and runs on
26.04 anyway, and is already installed and logged in**. No Docker-container or manual-BSP workaround
is needed. Keep masn out of it; there is no reason to move the board to the office.

GOTCHA: `sdkmanager --cli` refuses to run while the GUI instance is open ("SDK Manager is already
running"). Close the GUI before scripting anything.

### What the board actually is (inventoried 2026-08-05, pre-flash)

Reachable **on the LAN** at `nvidia@orin.internal` = `192.168.50.200` (DHCP, MAC `48:b0:2d:d8:93:c9`).
It also brings up the USB device-mode link at `192.168.55.1`.

| | |
|---|---|
| Model | NVIDIA Jetson AGX Orin Developer Kit |
| OS | Ubuntu 24.04.3 (noble), kernel `6.8.12-debug-tegra`, built 2025-11-04 |
| L4T | `R00 (debug), REVISION: 0.0, BOARD: generic` — a debug build, not a production release |
| JetPack | **none** — no `nvidia-l4t-*` packages, no CUDA, no TensorRT, no `jetson_release` |
| Docker | **not installed** |
| Root | `/dev/mmcblk0p1` — the 64 GB eMMC (57.8 GB partition, 45 GB free) |

Ubuntu 24.04 + kernel 6.8 is JetPack 7 lineage, and none of the L4T runtime is installed. So the
reflash to 6.2.2 is confirmed necessary — as it stands this board cannot run the `jp6` Frigate image
and has no CUDA at all. Nothing on it is worth preserving.

**There is no NVMe.** The M.2 Key-M slot is empty: `lspci` shows only the RTL8822CE Wi-Fi card in the
Key-E slot, and no `/dev/nvme*` block device exists (`/dev/nvme-fabrics` is a kernel control node, not
a disk). **User is ordering an M.2 2280 drive (decided 2026-08-05); flash waits for it.**

Why not just use the eMMC — the deciding argument was that **eMMC is soldered to the module**, so
wear-out is a module-level problem rather than a $60 swap, on the box this migration makes
must-never-be-down. This project already lost a boot device that way (masn's WD Blue,
`Media_Wearout=001`). Secondary: Frigate writes `frigate.db` continuously 24/7, eMMC exposes only
coarse 10%-bucket lifetime via `mmc extcsd read`, and §6 step 3 wants room for several TensorRT engine
caches. Speed was NOT a real factor — recordings go to the NAS at 64 MB/s over 1GbE, so eMMC would
never have bottlenecked the recording path.

**The drive must be installed BEFORE flashing** — SDK Manager can only target a disk that is present
at flash time, and moving root off eMMC afterwards means a second flash or a manual rootfs clone plus
bootloader retarget.

Ordered 2026-08-05: **SanDisk Optimus 5100 NVMe 500 GB** (`SDSP51500GAN-000E0`) — M.2 2280,
PCIe 4.0 x4, ~6600/5600 MB/s, 5-yr warranty. Verified compatible: the slot is **M.2 Key-M, 2280,
PCIe Gen4 x4, NVMe only — no SATA M.2**, so this is a direct match at full host link width.
(Name confusion worth noting: "SanDisk Optimus" was formerly a 2.5-inch enterprise **SAS** line;
the 5100 is the current M.2 NVMe reuse of the name.) Physical install: 4 screws on the **underside** of the devkit (under the rubber feet on
some variants) split the case; the slot is **J1** on the carrier board, which NVIDIA's layout doc
lists under *"Top View (Hidden under the Module)"* — i.e. beneath the module assembly. Remove the
retaining screw at the 2280 standoff, insert at an angle, seat flat, refasten. IP `192.168.50.200` was
reserved against the MAC on 2026-08-05.

**The cabling gotcha:** the AGX Orin devkit has two USB-C ports and they are not interchangeable.
- **Power** = the USB-C port *above the DC jack*.
- **Flashing to the host** = USB-C port *next to the 40-pin connector*.

Steps:

1. ~~Install SDK Manager~~ — **DONE**, installed and logged in on naahmed-linux.
2. **Force Recovery Mode**: hold the *middle* Force Recovery button while inserting the USB-C power
   plug. It powers on directly into recovery. Confirm with `lsusb`: recovery mode enumerates a
   *different* NVIDIA ID than the booted board does. While booted it shows `0955:7020` ("L4T running
   on Tegra") — if you still see `7020`, it is NOT in recovery.
3. Connect the flashing USB-C port to naahmed-linux. Confirm detection: `lsusb | grep -i nvidia`.
4. Flash, **targeting the NVMe rather than the 64 GB eMMC** — Frigate's model cache, DB and logs all
   want the faster, larger, replaceable device:
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
6. Post-flash: set a static IP or DHCP reservation, enable SSH, add it to `~/.ssh/config` as `orin`.

   **POWER MODE — start at the DEFAULT, scale up only if inference demands it (decided 2026-08-05).**
   This REVERSES the original instruction here, which said to set `nvpmodel` to max and run
   `jetson_clocks`. Reasons: six cameras are a small fraction of this board's capacity, the Orin is
   becoming 24/7 always-on infrastructure, and MAXN on the 64 GB AGX runs to ~60 W for a workload that
   does not need it. Scaling up later is one command; the risk of starting high is that nobody ever
   turns it back down.

   - **Do NOT run `jetson_clocks`.** That pins clocks to the maximum of whatever mode is active and
     defeats DVFS. Leaving it off is the single biggest power saving and costs only a little latency
     variance. It is also not persistent across reboot unless deliberately made so.
   - **ANSWERED 2026-08-07, post-flash: the default is `MODE_30W` (mode 2), NOT MAXN.** So the fresh
     flash already lands where this section wants it and no capping command is needed. The widely
     repeated "AGX Orin defaults to MAXN" claim did not hold for this board on JetPack 6.2.2.
     (`nvpmodel -q` reads the mode without sudo; `nvpmodel -p --verbose` lists them.)
   - **Then measure before changing anything**: `tools/frigate-detector-stats.sh`. The HD 630 baseline
     to beat is 28-31 ms with detect fps 3. If the Orin clears that comfortably at a capped mode,
     there is no argument for more power.
   - Raise the mode only if measurement shows a real deficit — and note in §6 that fps 5, a bigger
     model and vehicles all get spent from the same budget, so re-measure after each.

   **If the voice/LLM node lands here too (user re-affirmed interest 2026-08-05), revisit this.** An
   LLM sharing the GPU changes the sizing question completely — see §8 "DLA" and the co-location
   warning in §1. Do not size the power mode for Frigate alone and then quietly add an LLM to it.
   The MAC (`48:b0:2d:d8:93:c9`) survives the reflash, so a UCG-Fiber DHCP reservation made now will
   still apply afterwards. It currently lands on `192.168.50.200` by DHCP — worth reserving that same
   address so `orin.internal` keeps resolving. Note there is **no `~/.ssh/config` entry yet**; today's
   access works only because `orin.internal` resolves via the LAN, and the account is `nvidia` with a
   password (no key installed). Install a key at OEM setup time.
   Docker is NOT installed on the board today — it comes with JetPack, but verify per §5 step 1.

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

1. ~~Docker + nvidia-container-runtime come with JetPack; verify `docker info | grep -i runtime`.~~
   **WRONG, corrected 2026-08-07.** JetPack installs the *packages* (`nvidia-container-toolkit`
   1.16.2 was present) but does **not register the runtime with Docker**: there was no
   `/etc/docker/daemon.json` at all and `docker info` listed no nvidia runtime. Without this the
   container gets no GPU and the TensorRT detector cannot start. Fix, needs sudo:
   ```
   sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
   ```
   Also note **sudo on the Orin requires a password**, exactly like masn — so the privileged steps
   are the user's to run, not something a session can do unattended. And the login user is *not* in
   the `docker` group on a fresh flash (`sudo usermod -aG docker nvidia`, then re-login).

   `orin-stack/setup-orin.sh` does all of this, gates on `TensorrtExecutionProvider`, and refuses to
   proceed if the board is not L4T R36 or the `.env` is incomplete.
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

### FIRST RESULT 2026-08-07 — the Orin is barely faster than the HD 630

Shadow instance up, TensorRT engine built for `sm87` (11 minutes, 53 MB), settled:

| | masn (HD 630, OpenVINO) | Orin (TensorRT) |
|---|---|---|
| inference | 29–30 ms | **27.22 ms** |
| det_fps offered | 10.5 | 10.7 |
| skipped_fps | 0.0 | 0.0 |

**~10% better, on hardware that should be several times faster.** Three causes found, most confident
first:

1. **It runs FP32 and there is no way to ask for FP16 from config.** In `get_ort_providers()`,
   `"trt_fp16_enable": requires_fp16 and os.environ.get("USE_FP_16", ...)`. But the ONNX detector
   calls `get_optimized_runner(path, device, model_type=...)` with no `requires_fp16`, so it defaults
   `False` and the `USE_FP_16` env var is dead code on this path. FP16 is roughly 2x on Orin.
2. **The graph is PARTITIONED.** Two engine files were produced (`_0_0_sm87`, `_1_1_sm87`), so ops
   TensorRT would not take fall back off the accelerator mid-inference.
3. **MODE_30W** leaves 8 of 12 CPU cores online and clocks them at 729 MHz much of the time, with
   GR3D bouncing 0–85% rather than pinned. The GPU is not obviously the ceiling.

**The deeper problem is the architecture.** Section 6.3 already noted Frigate gives YOLO-NAS only
"limited" support on Nvidia. It is worse than that: `CudaGraphRunner.is_model_supported()` explicitly
EXCLUDES `yolonas`, and TensorRT partitions it. So the Frigate+ model trained on 2026-08-07 is a
`yolonas` custom model — i.e. **we trained into the one architecture that is slowest on this
hardware.** Frigate+ base models include `yolo-generic` yolov9t at 320 and 640 supporting the `onnx`
detector; a future training should use that base if the Orin is the target.

**Next, in order.** (a) Raise `nvpmodel` to MODE_50W (3) or MAXN (0) and re-measure — this is the
measured deficit the power decision in section 3 said to wait for, it is one command, and it is
instantly reversible. (b) If power is not the answer, the architecture is, and the fix is a Frigate+
retrain on a yolov9 base rather than any amount of tuning here.

Not urgent: masn is still serving detection, and the shadow publishes to `frigate_orin` so nothing
live depends on it.

### SECOND RESULT 2026-08-07 — yolov9s @ 640 is nearly free, and fine-tuning beats resolution

Switched the shadow to the Frigate+ **base** `yolov9s` 640 (`plus://de319e7a...`, no training slot).
Engine built in 5 min — *faster* than the 11 min yolonas 320 took, despite 4x the pixels.

| | masn: yolonas 320 openvino | Orin: yolonas 320 TRT | Orin: yolov9s 640 TRT |
|---|---|---|---|
| inference | 25.6 / 26.1 ms | 30.5 ms | **33.9 ms** |
| offered | 21.5 det/s | 22.7 | 24.1 |
| skipped_fps | 0.0 | 0.0 | **0.0** |

**4x the pixels and a better architecture for ~11% more latency than the Orin's own 320 run.** This
is the answer to "what did the Orin buy": not lower latency — masn is still faster per inference —
but the capability to run a far bigger model without dropping a frame. Size the box on that, not ms.

**One detector is no longer enough.** Utilisation went 75% -> 82% across successive samples with
`det_fps` still CLIMBING (22.3 -> 24.1), not settling. No frames dropped yet. Add `onnx_1` before
this is load-bearing; the plan's own advice is that a detector process runs inferences serially.

**The merging result is the interesting one:**

| model | driveway flicker-like (d<0.30) |
|---|---|
| yolonas 320, BASE (masn, pre-Frigate+) | 66% |
| yolov9s 640, BASE (Orin) | **35%** |
| yolonas 320, CUSTOM 22 images (masn) | **1%** |

Architecture + resolution roughly HALVED the flicker. Fine-tuning on 22 of your own images took it
from 66% to 1%. **Both help; fine-tuning helps far more** — so the pending custom `yolov9s` training
should combine them and is the right thing to spend a slot on. It also means the Orin migration was
never the fix for box merging; Frigate+ was, and the Orin is what lets a bigger model run.

CAVEAT: 54 scored tracks over ~20 minutes at one time of day, against a 4 h window for the 1%
figure. Directionally clear, not a settled number. Re-measure over a full day.

### THIRD RESULT 2026-08-08 — the custom yolov9s runs well; the flicker comparison is UNRESOLVED

Deployed `plus://54f2f55d...` (yolo-generic 640, **96 verified images**, driveway 81 vs 15 in the
first run). Performance is settled and comfortable: **35.9-44.3 ms** across two processes, **16-29%**
utilisation, **0.0 skipped**, CPU 16-19%. Engine built in ~1 min reusing the timing cache. The 640
custom model has more headroom on the Orin than the 320 model has on masn.

**The flicker comparison did NOT work, and the reason is a methodology error worth not repeating.**
Measured over 4.25 h overnight and set against the base model's 4.4 h evening window:

| window | events | scored | flicker |
|---|---|---|---|
| Orin, yolov9s 640 BASE (evening) | 151 (34.3/h) | 122 | 20% |
| Orin, yolov9s 640 CUSTOM 96img (overnight) | 10 (2.4/h) | 8 | 12% |
| **masn CONTROL, same overnight window** | **6 (1.4/h)** | **6** | **33%** |

Running masn over the IDENTICAL wall-clock window is what exposed it. The apparent collapse from
34.3/h to 2.4/h is **time of day, not the model** — masn fell to 1.4/h in the same hours. And on 6-8
scored tracks a "percentage" is 1-2 events; masn's own flagship 1% figure reads 33% here on 6 tracks.

**Do not compare flicker across windows with different traffic.** Any future model comparison needs
a DAYTIME window with hundreds of scored tracks, and a same-window control on the other box. Both
boxes persist their events in SQLite, so this can be done retrospectively — no live capture needed.

**The 17 "crashes" were the CAMERA, not the Orin.** Clustered in a 2-minute burst at 05:38-05:39,
all four TrackMix streams (driveway + driveway_tele, main + sub) failing RTSP DESCRIBE with 404.
masn logged **16 crashes in the same window** with "Connection timed out". The TrackMix dropped off
the network for ~2 min and both instances recovered. Not NVDEC, not the shadow doubling RTSP client
load, not the Orin. Worth watching as its own issue.

Still open before cutover: the unexplained `free(): invalid pointer` shutdown abort from 2026-08-07,
which has NOT recurred in the 4 h since.

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
3. **A bigger model / higher resolution.** Researched 2026-08-05 against the Frigate 0.17 detector
   docs. Note first that **`yolo_nas_s` is a poor fit for this hardware** — it was chosen for
   OpenVINO on the HD 630, and on Nvidia Frigate gives full **CUDA Graphs** optimisation to YOLOv9,
   YOLOx and RF-DETR but only *limited* support to YOLO-NAS. Carry it over for the §5 shadow
   comparison (apples-to-apples), then move off it.

   | Model | `model_type` | Resolutions | Sizes | CUDA Graphs |
   |---|---|---|---|---|
   | YOLOv9 | `yolo-generic` | 320, 640 | t/s/m/c/e | full |
   | RF-DETR | `rfdetr` | **320 only** | N/S/M | full |
   | D-FINE | `dfine` | 640 | s/m/l | no |
   | YOLO-NAS | `yolonas` | 320, 640 | s/m/l | limited |

   **Highest-value change is probably RESOLUTION, not architecture.** The false hits that forced
   `min_area: 0.005` are fixed objects across the street occupying 0.09-0.40% of frame — at 320x320
   input those are roughly 20px objects, and 640 quadruples the pixels on them. That is the direct
   attack on the actual discrimination problem. It also means **RF-DETR's 320-only limit is a real
   drawback here**: YOLOv9 at 640 may well beat RF-DETR at 320 for these distant small objects,
   despite RF-DETR being the stronger architecture. Try `yolo-generic` at 640 FIRST.

   RF-DETR remains worth testing for one specific reason: DETR-family models do set-based prediction
   with **no NMS**, and parked-car box flicker is plausibly an NMS/anchor artifact. That attacks the
   flicker failure mode structurally rather than just being "more accurate". HYPOTHESIS, untested —
   see §8.1. D-FINE is the weakest fit on this box (no CUDA Graphs).

   **CAVEAT — Frigate+ was approved 2026-08-05 and largely SUPERSEDES this table.** A Frigate+ model is
   configured as `path: plus://<model_id>` with **all other model fields removed** (architecture and
   resolution are set automatically), so the free choice above collapses to whatever Frigate+ offers on
   the jp6/TensorRT path — not yet determined. Frigate+ is also a *better* answer to §8.1 than any
   architecture swap, because it fine-tunes on your own submitted false positives. Decide Frigate+ vs
   free-model-tuning BEFORE spending effort here. See `../masn-stack/OPEN-THREADS.md` thread 5.
4. Reconsider `min_area: 0.005` and the detect-fps-driven tuning; some of it was compensation for a
   starved GPU and may no longer be needed.

### BLOCKER FOR CUTOVER 2026-08-08 — Frigate does not survive a reboot

Rebooted the Orin deliberately to test it. **Frigate did not come back.**

```
ExitCode=143
Error=failed to mount //<NAS>/frigate/orin-shadow ... network is unreachable
Restarts=0
```

Docker starts the container before the network is up, the cifs volume mount fails, and **Docker does
not retry** -- `restart: unless-stopped` does not cover this because the failure is at VOLUME-MOUNT
time, before the container starts. So it simply stays down until someone notices. The NAS was fine
throughout (ping and 445 both good immediately after).

This had already happened once on 2026-08-07 and was misread then as a transient network blip. It is
not transient, it is deterministic, and it is **disqualifying for a box that becomes
must-never-be-down** — the whole premise of section 7 is that the Orin can be relied on.

**Fix: `orin-stack/frigate-stack.service`**, a systemd oneshot ordered `After=network-online.target`
that runs `docker compose up -d` with a 30 x 10 s retry loop. The retry matters as much as the
ordering: `network-online.target` only means the interface has an address, not that the NAS is
answering SMB — a NAS still booting will refuse. `setup-orin.sh` step 7 installs it.

Deliberately NOT fixed by bind-mounting the share via fstab: the docker cifs volume is what makes
Docker refuse to start Frigate when the NAS is unreachable rather than silently recording to the
local NVMe. That hardening is worth keeping; this fixes the ordering without weakening it.

**VERIFIED FIXED 2026-08-09 by a second deliberate reboot:**

```
20:43:48  Starting Frigate stack with NAS-aware startup...
20:43:49  Error ... network is unreachable
20:43:49  attempt 1 failed (NAS not ready?), retrying in 10s
20:43:59  Container frigate Starting
20:44:02  Container frigate Started -- unit Finished
```

The first attempt still fails — the race is real and unavoidable at that point in boot — but ONE
retry was enough. **Unattended recovery in ~14 s**, cifs mounted, healthy at +2 min, engine reloaded
from the TensorRT cache (no rebuild), 39.8/40.8 ms across two detectors, det_fps 22.0, zero skipped
frames, running the custom yolov9s 640.

This closes the cutover blocker. Note the fix does NOT prevent the first failure; it survives it.

Good news from the same reboot: the `free(): invalid pointer` shutdown abort did NOT recur.

## 6b. CUTOVER DONE 2026-08-09 21:47 UTC

Frigate now runs on the Orin. masn's instance is stopped but defined.

```
model        plus://54f2f55d...  custom yolov9s 640, 96 verified images
detectors    2 x onnx/Tensorrt    inference ~39 ms, det_fps 15-22, skipped 0.0
decode       NVDEC (preset-jetson-h264)
recordings   real NAS share, 15-day retention
database     masn's, migrated -- integrity ok, 11,649 events, 721,870 recordings, 96 plus submissions
mqtt         topic_prefix back to `frigate`
detection gap ~13 s
```

Verified after: 300 recording segments in the first 8 minutes, 50 on each of the six cameras;
events flowing; HA integration error-free after reconfiguring its URL; `camera.driveway` and
`camera.front_door` reporting `recording`.

**Why it was safe to go:** a matched 8 h DAYLIGHT window on both boxes (the overnight comparison was
worthless -- 6-10 events) showed them indistinguishable:

| driveway, 8 h daylight | masn yolonas 320 | Orin yolov9s 640 |
|---|---|---|
| flicker-like (<0.30) | 6 = **7%** | 6 = **7%** |
| real movement (>=0.5) | 79 = 89% | 73 = 89% |
| all events, all cameras | 310 (38.8/h) | 223 (27.9/h) |

Same quality, 28% fewer total events, at 4x the resolution with headroom to spare.

### Gotchas hit during the cutover — read before doing anything like this again

- **`cat > file` needs write permission on the FILE**, not just the directory. `frigate.db` is
  root-owned 644 and the copy failed `Permission denied` while the loop reported success, because
  only the last command's status was checked. The Orin briefly came up on the SHADOW database.
  Delete the target first (the dir is user-owned, so unlink is allowed) and verify byte sizes match.
- **`frigate.db-wal` will not exist** once Frigate is stopped -- SQLite checkpoints it into the main
  DB. That is correct, not an error; do not treat its absence as a failure.
- **Renaming the volume was REQUIRED.** Docker does not re-read `driver_opts` on an existing named
  volume, so editing the device path in place is silently ignored and it keeps mounting the old
  target. `frigate_media_shadow` -> `frigate_media` is what forced the real share.
- **`ORIN_LAN_IP` must be in `.env`.** Empty makes `"${ORIN_LAN_IP}:5000:5000"` bind to ALL
  interfaces -- the opposite of the intent.
- **`:5000` on the Orin is not reachable from the Orin itself** any more; it binds to the LAN IP.
  Test from masn, and test the block from a THIRD machine (neither masn nor the Orin) -- from either
  of those it looks fine regardless.
- **Firewall the published port in DOCKER-USER, not ufw/INPUT.** Docker's DNAT rules in
  `nat/PREROUTING` are evaluated first, so an INPUT rule appears to work and blocks nothing.

### Still to do

- Prove the notification path with a real person event (needs someone to walk up).
- After masn has been cold a week: delete the `orin-shadow` directory and the `frigate_media_shadow`
  volume, reclaiming 568 GB.
- Phase 4 remains unspent: detect fps 3 -> 5 (the 2026-08-04 emergency cut), face recognition, LPR,
  `package` tracking. One change at a time, measuring between each.

## 7. Rollback

Keep masn able to take Frigate back for at least a week: leave its compose service defined (stopped),
leave `yolo_nas_s.onnx` in place, and do not delete `/opt/stack/frigate/config`. Reverting is: start
masn's Frigate, point HA back at `127.0.0.1`, re-bind mosquitto to loopback. The config in git at tag
`eef43e1`/`988319d` is the known-good HD 630 state.

Given the Orin becomes must-never-be-down, also decide: what happens on an Orin failure? Today masn is
the answer. Do not let that quietly stop being true.

### DECIDED 2026-08-05: do NOT move HA to the Orin. masn stays.

Asked because the Orin becomes always-on anyway and masn burns power. Rejected, for three reasons:

1. **It collapses the fallback this very section demands.** Today an Orin failure costs cameras. With
   HA there too it costs cameras, every automation, the garage door, the thermostat, notifications and
   remote access simultaneously. Two boxes mean one can die and the house still works.
2. **JetPack upgrades are REFLASHES, not `apt upgrade`.** A vendor-pinned embedded OS where 6 -> 7
   wipes the device is fine for a camera appliance and bad for the machine running the house. masn's
   plain Ubuntu Server upgrades in place for years.
3. **The power premise is partly self-correcting.** Much of masn's current draw IS Frigate — YOLO-NAS
   pins the HD 630 at its 1150 MHz maximum continuously. After the migration masn is a near-idle
   i7-7700 running HA + Postgres + Mosquitto + Z2M + matter-server. Measure the machine you will
   actually have, not the one you have now.

**Action instead of consolidating: MEASURE.** Put one of the existing HA power-monitoring plugs on masn
now for a baseline, re-read a week after Frigate moves, then tune idle draw (C-states,
`powertop --auto-tune`). Expect the delta to make the question moot.

Landmines if it is ever reconsidered: **matter-server fabric state** for the Aqara W200 (Matter
re-commissioning is painful if the move corrupts it) and masn being the **Tailscale subnet router**
advertising `192.168.50.0/24`, which would have to move too. One thing that would be easy: the SLZB-06
is network-attached, so Zigbee has no USB passthrough to migrate.

Revisit only if a second always-on box exists (so the Orin is not singular), or if measurement shows
masn drawing far more than expected post-migration — deliberately, not as a side effect.

## 8. Open questions

- **Does the migration actually fix the parked-car flicker?** Still unanswered. It is the reason for
  all of this, and Phase 4.2 is the first time it gets tested.
- **NVDEC for decode.** The Orin should decode camera streams on dedicated NVDEC silicon rather than
  the GPU — that separation is the whole architectural point. Verify Frigate is configured to use it
  (`h264_nvv4l2dec` / the jetson ffmpeg preset) rather than falling back to CPU decode.
- **DLA.** ~~Unconfirmed~~ — **ANSWERED 2026-08-05, and the answer is no.** The Frigate docs confirm
  DLA placement (`-dla` model-name suffix, Xavier/Orin only) works exclusively through the **legacy
  `tensorrt` detector with YOLOv3/v4/v7** models at 288-896. Modern models — YOLOv9, RF-DETR, D-FINE,
  YOLO-NAS — run through the **`onnx` detector**, which has no DLA path. So **"best model" and "DLA
  placement" are mutually exclusive in Frigate today**; you pick one. While the Orin is Frigate-only
  this costs nothing (GPU headroom is enormous), so take the better model. It only becomes a real
  trade-off if an LLM node lands here and starts competing for the GPU — at which point moving
  detection to DLA would mean regressing to YOLOv7.
- **Power/thermals/siting** — the Orin becomes always-on infrastructure; where it lives, and on what
  UPS, is unaddressed. Power MODE is now decided (§3 step 6: start at default, no `jetson_clocks`,
  scale up only on measured need). Siting and UPS are still open.

- **VOICE/LLM CO-LOCATION on the Orin — user re-affirmed interest 2026-08-05.** `AGENTS.md` defers
  this to Phase 7 (local Assist: whisper + Piper + Ollama over Wyoming), and the 64 GB of unified
  memory is what makes a serious local model viable. But it is not a free addition, and the
  consequences are specific:
  - **It re-couples security to an experimental workload.** §1 already records that Frigate makes the
    Orin must-never-be-down. An LLM stack is something you restart, upgrade and tinker with. If both
    live here, tinkering risks the cameras. Container resource limits (GPU/memory) so the LLM cannot
    starve the detector are a hard requirement, not a nicety.
  - **It reopens the DLA question above.** While Frigate is alone the GPU has huge headroom, so the
    better ONNX models win. If an LLM competes for the GPU, the escape hatch is moving detection to
    DLA — which means regressing to the legacy `tensorrt` detector on YOLOv7. That is a real cost to
    weigh BEFORE committing to co-location.
  - **It changes the power sizing.** Do not pick a capped `nvpmodel` for Frigate alone and then add an
    LLM underneath it without re-measuring.
  - **Decide the failure story first.** With HA still on masn (see the consolidation decision), an
    Orin failure costs cameras plus voice — recoverable. That is only true while masn stays.
- **The VOD 503 bug is independent of all this** and travels with you. `front_door` intermittently
  writes 2-second segments instead of 10-second (hour 12 today: 1592 segments vs a normal ~360),
  overflowing nginx-vod's durations array so a 1-hour playback request returns HTTP 503. Moving
  hardware will not fix it.
