# Open threads — cameras / notifications / detector

Portable, git-tracked record of the camera-stack work that is **in progress or deliberately paused**, so
any session (including one running on masn) can pick it up without prior context. High-level status lives
in `../AGENTS.md`; this file is the detail. Last updated 2026-08-04.

## Frigate — current live state

OpenVINO on the HD 630 iGPU, model **`yolo_nas_s` (320x320, coco-80)** as of 2026-08-04, **6 cameras +
the TrackMix tele lens** via go2rtc, 24/7 continuous recording to the NAS, **PERSON detection only**.
Config: `frigate/config/config.yml`. Two detector processes (`ov_0`/`ov_1`), both on the iGPU.

## 1. Vehicle detection + notifications — DISABLED, with a fix kept for later

**Disabled 2026-08-02.** The weak ssdlite model spawned a flurry of false *moving-car* alerts. Root cause:
two adjacent **parked** cars' boxes oscillate between two fixed positions (the detector conflates them),
fabricating a steady 5-11 km/h *estimated* speed. Neither the instantaneous `speed_threshold` (single-frame
spikes) nor `average_estimated_speed` (inflated by the repeated spikes) separates flicker from a real car.

**The robust discriminator is trajectory DIRECTNESS** = net displacement (start→end) / total path length.
Real cars ~0.99-1.0 (straight down the lane); flicker ≤0.13 (oscillates in place). Only knowable from
`data.path_data` (the centroid track), which Frigate populates ~8 s after lane entry.

**DETECTION RE-ENABLED 2026-08-05** (commit `ab8112c`) — `track: [person, car, motorcycle]`.
Notifications stay off (`automation.frigate_moving_vehicle` verified `off`, last_triggered
2026-08-02), so events generate for inspection and nothing pushes. NOTE the label correction: it is
**NOT** `car,bus,motorcycle` as this thread previously said — Frigate's `/labelmap/coco-80.txt`
remaps bus (idx 5) and truck (idx 7) onto `car`, so listing `bus` is dropped with a warning.

**MEASURE IT WITH `tools/frigate-vehicle-flicker.sh`** (added 2026-08-05), which scores every car
event by directness and reports what the automation would have done. Run a SHORT window (`12`) so it
does not mix in pre-2026-08-05 ssdlite events; it cannot tell which detector produced an event.

**ssdlite BASELINE to beat** (96h run = ~13h of active detection before the 2026-08-02 disable):

| | |
|---|---|
| car events | 1363 |
| flicker-like (directness <0.30) | 607 = **44.5%** |
| real movement (>=0.5) | 529 = 38.8% |
| driveway camera | 585 flicker of 1141 |
| fabricated speed on flicker | mean 2.47 km/h, max 12.65 |

**The directness gate is LOAD-BEARING, not belt-and-braces** — this thread's open question, now
answered for ssdlite: of **86** events that entered `driveway_lane`, only **18** would have notified;
the gate suppressed **68** (79% of zone entries were false). Whether YOLO-NAS still needs it is the
open part. Keep the gate either way.

### FIRST YOLO-NAS RESULT (2026-08-05, 1h window, daylight) — flicker NOT fixed, but DEFUSED

15 car events in the first hour (14 on `driveway`). Verdict is genuinely mixed, and the headline
percentage is misleading on its own:

| | ssdlite | yolo_nas_s |
|---|---|---|
| flicker-like share | 44.5% | **66.7%** (10/15) |
| event volume | ~105/h | **~21/h** |
| fabricated speed, mean | 2.47 km/h | **0.57 km/h** |
| fabricated speed, max | 12.65 km/h | **0.88 km/h** |
| entered `driveway_lane` | 86 | **0** |
| would have NOTIFIED | 18 | **0** |

**The boxes still oscillate — but the amplitude collapsed.** Directness is still low, so the flicker
is not gone as a detection-stability problem. What changed is magnitude: fabricated speed dropped ~4x
and now never reaches the zone's `speed_threshold: 5`, so **nothing enters `driveway_lane` and the
automation could not fire even if it were on**. Event volume also fell ~5x. Small sample (1h) — rerun
over a full day before trusting the numbers.

**Remaining symptom: the RED BORDER in the Frigate web UI.** Not HA, not Reolink's on-camera AI
(`binary_sensor.garage_vehicle` had 0 ON transitions in 6h). It is Frigate's own Live view reacting to
**`severity: alert` review items** — `driveway` has `review.alerts.required_zones: front`, the parked
cars sit in `front`, and `car` is a default alert label. So every re-detection of a parked car raises
an alert. Options if it becomes annoying: restrict driveway alert labels to `person` (cars stay as
`detection` severity, no red), a `car` min_area gate, or a mask over the parked-car region.

**This is the prime Frigate+ training case (thread 5)** — these events are exactly the images to
submit. User began submitting 2026-08-05.

### ROOT CAUSE IDENTIFIED 2026-08-05 — box MERGING, not box "flicker"

Frigate's Tracked Object Details view caught it directly: **one `car` detection at 69% whose box
spans TWO vehicles** — the sedan behind and the foreground SUV, enclosed in a single box. The
oscillation is the detector alternating between emitting ONE merged box and TWO separate boxes. Each
flip moves the centroid by half a car length, which is the fabricated displacement the directness
metric sees. So this is an **instance-separation failure on adjacent same-class objects**, not a
localisation jitter.

**The merged population is measurable and bimodal by AREA** (58 driveway car events, 3h):

| | area, fraction of frame |
|---|---|
| min | 0.0018 |
| **median (single car)** | **0.0873** |
| **top cluster (MERGED)** | **0.149 - 0.191**, w/h 0.41-0.53 |

A merged box is ~2x a single car. Scores across that merged cluster run 0.51-0.88, so — exactly as
with the person false positives — **`threshold` cannot separate them; only AREA can.** A `max_area`
car filter around 0.13 would reject merges, BUT a real car pulling up close to the camera also gets
large, so it risks blinding genuine driveway events. Not applied; recorded as an option.

Why higher resolution is NOT the fix: these cars are huge in frame and already well resolved at 320.
The model is not short of pixels, it is choosing to call two objects one. The architectural fix is a
**NMS-free DETR-family model (RF-DETR)**, whose 320-only limit in Frigate costs nothing here precisely
because the objects are large. The practical fix is **Frigate+ fine-tuning with both cars labelled as
SEPARATE instances** in the submitted frames.

### FAILED EXPERIMENT — `max_disappeared: 45` did not reduce churn (2026-08-05)

Theory was that parked cars were being dropped after 5 s undetected and re-acquired as new objects.
Raised `max_disappeared` 15 -> 45 frames on `driveway` (commit `d3af0dc`). Result: driveway car
events went **~21/h -> 46/h**, i.e. no improvement and possibly worse. Confounded by rising afternoon
activity, so it is not proof of harm — but there is no evidence of benefit, and it carries a real
tradeoff (all objects on that camera, including people, held 15 s instead of 5 s before their event
closes). **Recommend reverting**; the churn is a symptom of the merge/split oscillation above, not of
premature object dropping.

### FRIGATE+ MODEL — merging looks FIXED (2026-08-07, 4 h, PRELIMINARY)

Deployed `plus://7cc1274d78a77a4a4951b6425822de55` (yolonas 320, trained 07:17Z off base 2026.2),
commit `de2051b`. Trained on only **22 verified images** (driveway 15) of 96 submitted. I predicted
no measurable movement from 15 frames. That was wrong:

| driveway | pre-swap (13.4 h) | post-swap (4.0 h) |
|---|---|---|
| car events | 39.9/h | 23.5/h |
| total events | 43.0/h | 28.9/h |
| flicker-like (d<0.30) | 66% | **1%** (1 of 75) |

The mechanism is the churn stopping, and the cars are **still detected** — this was checked, because
"model went blind" produces the same headline numbers:

- Anchored in the parked cluster (x 0.69-0.84, y 0.60-0.80): **pre 224 of 537 events (42%)**,
  spread over 224 separate short events; **post 1 of 95 (1%)**.
- A live in-progress car object sits at that exact spot, box area **0.095** — matching the
  single-car signature (~0.087), NOT the merged band (0.149-0.191).
- Mean car event duration rose 202.9 s -> 491.8 s.

So the parked cars are now held as ONE persistent object instead of 224 churn events. That is the
outcome we wanted, arrived at from a training set I judged too small to matter.

**NOT yet confirmed.** 4 h afternoon window against a 13.4 h overnight baseline; the strongest single
piece of evidence (the stable in-progress object) is one moment in time. Re-measure across a full
overnight before treating this as settled. Beware reading the post-swap box stats naively: median
anchor moved to x 0.42/y 0.20 and median area fell 0.049 -> 0.008 purely because the churn events
that dominated the old population are gone, leaving distant street traffic — not because boxes shrank.

**Detector load nearly doubled**, and it is NOT from driveway:

| det_fps | pre | post |
|---|---|---|
| driveway | 6.0 | 5.5 |
| front_door | 2.4 | 4.9 |
| west_gate | 0.3 | 2.7 |
| east_gate | 0.6 | 3.1 |
| backyard | 1.8 | 3.4 |
| **total** | **10.5** | **19.6** |

The new model simply finds more on the other cameras. Inference 27.4/28.4 ms, CPU 24.5%, ~28%
detector utilisation — fine, but it halves the headroom, which matters on the iGPU that crash-looped.

Next: verify the remaining ~74 submissions and retrain (11 of 12 slots left). Then consider tracking
`package` — available in this model's labelmap but deliberately NOT enabled yet, so it cannot
confound this measurement.

Kept in the repo, disabled, ready to re-enable now that the detector is upgraded:

- `frigate/config/config.yml`: `objects.track: [person]` (vehicles removed). The `driveway_lane` speed
  zone is left in place (`distances: 9.5,6.5,9.5,6.5` real-world m per side; `speed_threshold: 5` km/h).
  To restore vehicles: re-add `car,bus,motorcycle` to `objects.track`.
- `homeassistant/packages/person_notifications.yaml`: `rest_command: frigate_get_event` (fetches
  `http://127.0.0.1:5000/api/events/{event_id}`) + the automation aliased "Frigate: moving vehicle"
  (entity `automation.frigate_moving_vehicle` — verified 2026-08-04, state `off`) with
  `initial_state: false` (stays OFF across restarts) and `trace: {stored_traces: 25}`. Flow: MQTT trigger
  on car/bus/motorcycle entering `driveway_lane` → `delay: 8s` → REST-fetch the event → compute a `fire`
  variable from the directness template (fires only when `net/total >= 0.5`) → `condition` on `fire` →
  `notify.mobile_app_mna`. Validated end-to-end on real `path_data` before it was disabled.

Gotchas: `rest_command` is NOT hot-reloadable (`homeassistant.reload_all` won't load a new one → `docker
restart homeassistant`); an automation with `initial_state: false` needs an explicit `automation.turn_on`
after a reload. Speed estimation needs a 4-point zone + `distances` + metric `unit_system`. Frigate events
expose `zones` (not `entered_zones`), `data.path_data` (list of `[[x,y],ts]`), `data.average_estimated_speed`,
`current_estimated_speed`, `velocity_angle`.

## 2. Detector upgrade — YOLO-NAS SWAP DONE on the Dell (2026-08-04)

**The free swap is live.** `ssdlite_mobilenet_v2` → `yolo_nas_s` @ 320x320, still OpenVINO on the HD 630.
Measured with `tools/frigate-detector-stats.sh`:

| | ssdlite (before) | YOLO-NAS, 1 detector | YOLO-NAS, 2 detectors |
|---|---|---|---|
| inference | 8.2 ms | 22.6 ms | ~30.9 ms (GPU contention) |
| utilisation | 23% | 70% | 43.9% per process |
| capacity vs offered | 121 vs 28 det/s | 44 vs 31 det/s | 65 vs 28 det/s |
| skipped frames | 0 | backyard dropping | ~0.4% of frames |

(2-detector column is a 20-sample / 5-minute run, not a spot check.)

YOLO-NAS is ~2.7x the latency of ssdlite, which pushed a single detector process to 70% and made
`backyard` (the heaviest camera) drop frames. **A second detector process is therefore part of this
change, not optional** — `ov_0` + `ov_1`, both on the iGPU. Two processes contend for the same GPU so
per-inference latency rises to ~31 ms, but total capacity roughly doubles to ~65 det/sec against ~28
offered. Detections verified correct after the swap (person @ 0.79-0.87).

Honest caveat: skipping is **not** quite zero — ~0.03/s spread across backyard/driveway/east_gate/
west_gate, about 0.4% of offered frames, where ssdlite was a clean 0. At 44% average utilisation this is
burst/queue contention, not saturation, and Frigate tracks objects across frames so it is not worth
chasing. A third detector process is the lever if it ever matters, at the cost of yet more GPU contention
(latency already went 22.6 → 31 ms going from one process to two).

### Getting the model file

Not bundled in the Frigate image and NOT auto-downloaded. `tools/export-yolonas.sh` regenerates it
locally (a port of upstream's Colab notebook to a throwaway `python:3.11` container). Its pins are all
load-bearing and were each found the hard way:

- **Python 3.11** — super-gradients (Deci-AI, unmaintained) breaks on 3.12+.
- **torch==2.2.2** — newer torch routes `torch.onnx.export` through the dynamo exporter, which needs
  `onnxscript`, which upgrades `onnx` past 1.16, which deleted `onnx.mapping`, which `onnx_graphsurgeon`
  (used to bake NMS into the graph) still calls. Net result is a 1 MB truncated file, not a model.
- **numpy<2** — torch 2.2 predates the numpy 2 ABI break (`Could not infer dtype of numpy.float32`).
- **opencv-python-headless** — the plain wheel's cv2 wants X11 libs a slim image lacks. Both wheels own
  the same `cv2/` dir, so you must uninstall BOTH then install headless, or you end up with no cv2.
- **the sed** — Deci's weight hosts are dead; upstream rewrites them to a CloudFront mirror.

The script validates the graph before you deploy it (~50 MB, 1 input, 1 output, final dim 7 = FLAT_FORMAT)
because Frigate's `openvino.py` otherwise rejects the model at startup.

### Still open

- **Does this actually fix the parked-car flicker?** UNVERIFIED — vehicles are still off, so the swap has
  not yet been tested against the thing that motivated it. That is thread 1's next step.
- **Frigate+ ($50/yr)** — model TUNED to your own cameras (12 trainings/yr), `model_type: yolonas` on
  OpenVINO. Still the best accuracy-per-effort if staying on the Dell, and now a drop-in (same model_type).
  **USER APPROVED buying it, 2026-08-05** — see thread 5, which folds it together with packages / face
  recognition / LPR. It is now a candidate answer to the flicker question above, not just an accuracy
  upgrade: you can submit the actual oscillating parked cars as training images.
- **Migrate Frigate to the Jetson AGX Orin — DECIDED 2026-08-04, plan written.** See
  **`../docs/orin-frigate-migration.md`** for the full plan (flash JetPack **6.2.2**, not 7.2 — Frigate
  publishes no jp7 image; the masn-side un-coupling; shadow-run then cutover; rollback). The HD 630 hit
  the plan's own documented relief-valve trigger (">~25ms = saturating"; we measured 28-31 ms), and the
  swap made video playback crawl because detection and VAAPI decode share the one iGPU. Orin is OWNED
  but NOT YET FLASHED. Note this reverses the plan's "security detection stays on the always-on box"
  principle — the Orin becomes must-never-be-down.
- **Coral TPU for the Dell** — REJECTED for accuracy: fast, but runs the SAME small model class, so NO
  accuracy gain. Doesn't solve the flicker.

## 3. Auto-dismiss notifications whose Frigate clip expired

Tapping an old push whose clip has aged out shows `{"success":false,"message":"Event not found"}` /
"Unable to connect". Plan: track sent notification event-ids → poll Frigate → `clear_notification` on 404
(needs `command_line` / `python_script`). Interim: set the notification `clickAction` to `/lovelace/cameras`
so a dead tap lands somewhere useful instead of erroring.

## 4. Ring-style timeline scrubbing

Smooth scrubbing doesn't work in the current UI. The `custom:advanced-camera-card` (Cameras view) is
confirmed JANKY — tapping jumps to a clip and the scrubber disappears. Plan: use **Frigate's native History
UI** directly (not iframed) as a phone PWA of `http://192.168.50.50:8971`, rather than the camera card.
Dashboard deploys target the single Overview: `tools/apply-dashboard.sh - homeassistant/dashboards/overview.json`.

## 5. Recognition — packages, specific people, specific cars (Frigate+ APPROVED 2026-08-05)

Researched 2026-08-05 against the Frigate 0.17 docs. Three *separate* mechanisms; only packages costs
money. **All of this is POST-CUTOVER work** — see the sequencing trap below.

### Packages -> Frigate+ only ($50/yr, user approved)

No free path exists. Stock COCO-80 has no `package` class, so no model swap reaches it. Frigate+ base
models add `package` plus delivery logos (`amazon`, `usps`, `ups`, `fedex`, `dhl`), and also `face` and
`license_plate` — which directly improve the two features below. 12 fine-tunings/yr; new base models
Jan/Apr/Jul/Oct 15; trained models stay accessible after cancelling.

**Frigate+ SUPERSEDES the model-choice table in the migration doc §6.3.** Config becomes
`path: plus://<model_id>` and **all other model fields must be REMOVED — they are set automatically**.
So you do not independently pick YOLOv9-at-640; Frigate+ decides the architecture and resolution. Which
architectures/resolutions it offers on the jp6/TensorRT path was NOT determined — the docs point at a
"Base Models" tab to test each. Settle that before assuming the 640 plan survives.

**GOTCHA: "Frigate+ models generally have much higher scores than the default model"** — thresholds must
be re-tuned after switching. That directly touches the hard-won `min_area: 0.005` and the score-overlap
finding (false hits 0.09-0.40% of frame vs real people 1.3-21%). Do not carry the old thresholds over
blind.

### Submission + annotation workflow (researched 2026-08-05)

**The yes/no in Frigate's UI is NOT annotation** — it only marks the detection true/false positive and
uploads the image. **Boxes are drawn on plus.frigate.video**, a separate site. This confused us once;
it is the single most important thing to know here.

1. **In Frigate**: yes/no on a snapshot -> uploads it.
2. **On plus.frigate.video**: annotate. `w` adds a box, arrow keys move, `Shift`+arrows resize, `del`
   removes, `d` marks an object genuinely difficult.
3. **Request a model** on the Models page, then set `path: plus://<model_id>` (all other model fields
   removed — they are configured automatically).

**For OUR merged-car frames** (thread 1 root cause): answer **no** (false positive) in Frigate, then on
the site **delete the merged box and draw TWO tight boxes, one per car**. Upstream guidance covers this
case explicitly — submit a misidentified object as a false positive *and* add the correct label;
overlapping boxes are acceptable there. **Answering "yes" to a merged box actively reinforces the bug.**
Annotation overrides the yes/no hint, so earlier mislabelled submissions can still be corrected.

Rules that matter for our case:
- **Label EVERY object in the frame**, not just the cars — unlabelled regions teach the model they are
  background.
- **Tight boxes.** Box tightness at training time determines box accuracy at runtime, which is exactly
  the failure we are trying to fix.
- Aim ~**80% true positives / 20% false positives**. An all-false-positive set skews the model.

**Do NOT request a training early.** Minimum is 10 verified images, but good results typically need
**~100 verified per camera**, and each request burns one of the 12 annual slots. Training takes up to
36 h. Build across lighting conditions first — our parked cars are black, so dawn/dusk/night look very
different to the model.

### Specific people -> Face Recognition (built in, free, 0.16+)

Detects `person` FIRST, then finds/recognises the face. Match attaches as a **`sub_label`**, so it flows
into the existing `person_notifications.yaml` — "Person detected" becomes "<name> detected" with no
restructuring. Two tiers: `small` (FaceNet, CPU) and **`large` (ArcFace, needs GPU/NPU) — take `large`
on the Orin**, this is exactly the headroom the AGX buys. Enrol via UI wizard; 20-30 varied images per
person. Defaults: `detection_threshold` 0.7, `recognition_threshold` 0.9, `min_area` 500px,
`unknown_score` 0.8. With Frigate+ add `face` to tracked objects for native detection instead of the
CV2 fallback.

### Specific cars -> LPR (built in, free, 0.16+)

Detects `car`/`motorcycle` FIRST, then OCRs the plate, refining as the vehicle crosses frame.
`known_plates` maps plate -> label, again a `sub_label`. Supports regex (`"[S5]LL 1234"` catches OCR
confusions) and `match_distance` tolerance; `format`, `enhancement` (0-10) and `min_area` for tuning.
**The TrackMix tele lens is the natural LPR camera** — there is a dedicated `type: "lpr"` camera mode
that skips normal object detection and runs plate detection off motion. With Frigate+ add
`license_plate` to tracked objects.

GOTCHA found 2026-08-05: **`driveway_tele` currently has `detect.enabled: False`** (record/view only,
5 fps, 896x512) — hence its 0.0 det_fps in stats. Using it for LPR means turning detection on for it,
making it a 7th detect stream. **Do NOT do that on masn** — the HD 630 is already at 28-31 ms and had
to have detect fps cut to 3. This is Orin-side work by construction. The dedicated `type: "lpr"` mode
is the cheaper route since it bypasses normal object detection entirely.

### SEQUENCING TRAP — read before starting any of this

Both recognition features ride on the base detector: face recognition needs a `person` detection, LPR
needs a `car` detection. **Vehicle detection is currently DISABLED (thread 1), so LPR is BLOCKED until
Phase 4.2 of the migration re-enables vehicles.** Get detection healthy on the Orin first. Layering
recognition onto a starved or flickering detector just relocates the problem.

### UNVERIFIED — check right after flashing, before building on it

The face-recognition and LPR docs both state an **AVX + AVX2** CPU requirement. Those are **x86**
instruction sets; the Orin's ARM cores do not have them. Frigate groups these as "enrichments" and the
enrichments page says *"Jetson devices will automatically be detected and used for enrichments in the
`-tensorrt-jp6` image"* — strongly implying AVX describes the x86 CPU fallback and Jetson runs them on
GPU. **The docs never say so explicitly.** Add a face-rec + LPR smoke test to the post-flash checks
alongside the `TensorrtExecutionProvider` gate.

## 6. iGPU contention crash-loop — FIXED 2026-08-06 by dropping VAAPI decode

User reported "a few frame drops". All six cameras' **detect** ffmpeg processes were crash-looping:
**2320 crashes in 28 h (~82/h, ~13 per camera per hour)**, each costing seconds of detection
blindness. Every crash had one signature, decode-side only, with no RTSP error and a clean go2rtc log:

```
[AVHWFramesContext] Failed to sync surface 0xf: 1 (operation failed).
[hwdownload] Failed to download frame: -5.   ->   Error while filtering: Input/output error
```

The kernel named the culprit:

```
i915: Resetting rcs0 for preemption time out
i915: frigate.detecto[981400] context reset due to GPU hang
i915: GPU HANG: ecode 9:1:8ed9fff2, in frigate.detecto [981400]
```

Both OpenVINO detectors run `device: GPU` on the HD 630; VAAPI decode for all six detect streams ran
on that same chip. Inference stalled past the i915 preemption watchdog, i915 reset the render engine,
and every in-flight decode surface died with it. ffmpeg cannot recover from that, so it exited.

**Fix:** `ffmpeg.hwaccel_args: []` — software decode. Confirmed over a **67-minute** soak: **0 crashes,
0 surface errors** (~92 expected at the old rate), all cameras at target fps, `skipped_fps` 0.0.

| | before | after (67 min) |
|---|---|---|
| ffmpeg crashes | ~82/h | 0 |
| Frigate CPU | 21.6% | 25.6% |
| inference | 29.0 / 29.9 ms | 32.0 / 32.5 ms |

An 8-minute sample early in the soak showed 27.5 ms and I briefly read that as an inference *gain*.
It did not hold. Software decode costs ~8% inference speed and ~4 points of CPU — it does not pay
for itself, it buys the crashes away. Still a good trade at ~17% detector utilisation.

**GOTCHA:** `hwaccel_args` defaults to the string `"auto"`, so *deleting* the key does NOT disable
hardware decode — Frigate re-detects VAAPI ("Automatically detected vaapi hwaccel for video decoding").
It must be an explicit empty list. Verify with `ps -eo args | grep ffmpeg | grep -c hwaccel` -> 0.

**Two things NOT established.** (1) The onset date — the container was created 21:06:54Z and first
crashed at 21:10:52Z, under 4 minutes later, so docker logs cannot see before it; this may long
predate 08-05. (2) Only ONE GPU hang is in the kernel journal against 2320 crashes. i915 suppresses
repeat error-state captures until the existing one is read, which would explain it, but that was not
verified.

**RECORDING was never affected** — hwaccel is applied only when `"detect" in ffmpeg_input.roles`
(`frigate/config/camera/camera.py`), and record is a separate stream-copy process. Coverage held at
23.8-23.9 h/day per camera throughout, which is why nothing looked wrong from the timeline.

This is evidence for the Orin migration, not just a bugfix: the HD 630 is at the point where compute
and decode cannot coexist. On the Orin, NVDEC and the GPU are separate engines. Revisit `hwaccel_args`
there — it should go back to hardware decode.

## 7. Recurring MULTI-CAMERA dropouts — cause not yet found (opened 2026-08-08)

Started as "why did the driveway camera crash at 05:38 on 2026-08-08". That specific event WAS
TrackMix-local — `driveway` and `driveway_tele` are the two lenses of one camera and both gapped,
nothing else did. Both Frigate instances saw it (masn 16 ffmpeg restarts, Orin 17) and both
recovered on their own, so it was the camera, not either host.

**But the recording-gap history shows a bigger, pre-existing problem.** Query
`recordings` for gaps > 45 s per camera over 14 days. Every camera has 15-32 of them, and many are
SIMULTANEOUS across cameras that share nothing but the network:

```
08-04 12:06:36-12:07:51   driveway, driveway_tele, west_gate, east_gate, backyard   (5)
08-02 17:51:26            driveway, front_door, west_gate, east_gate                (4, same second)
08-04 16:03:33-38         driveway, front_door, west_gate, east_gate                (4)
08-06 15:55:33-36         driveway, front_door, east_gate, backyard                 (4)
08-08 04:54:12-18         driveway_tele, east_gate, backyard                        (3)
```

Different models (TrackMix, doorbell, CX810 x2, Duo 2) at different IPs going down in the same
second is not five cameras failing. It is something shared. Roughly one such event every 1.5 days.

**Ruled out, with evidence:**
- **NAS / CIFS write stalls** — no CIFS errors in the kernel log at any gap time; the only CIFS
  lines are mount operations at container restarts.
- **masn's NIC** — no link up/down events; the only entries are veth churn from container restarts.
- **Frigate restarts** — restart times were extracted from the CIFS remount log. Only ONE of nine
  multi-camera gaps (07-30 16:57) matches a restart. There were NO restarts at all on 08-06 or
  08-08, yet both days have multi-camera gaps.
- **Cameras being unreachable now** — all five answer ping and have 80/443/554 open.

**UniFi investigated 2026-08-08 with a local admin account. Switch EXONERATED; cause still unknown.**

```
USW Pro Max 16 PoE   uptime 10.8 d   PoE 39.7/180 W (22%)   temp 33 C   1 rx error total
UCG Fiber            uptime 11.5 d   switch uplink = gw port 3, 0 errors
```
Nothing rebooted during any outage. PoE nowhere near budget, so no shedding. Port error counters are
essentially zero. And camera client uptime (119-155 h) never reset across the 08-06/07/08 outages,
so the LINKS never went down -- ports stayed up while traffic stopped.

**Correct topology (an earlier reading of this was WRONG):**
```
USW Pro Max  p1 front_door   p2 east_gate   p3 driveway   p4 backyard   p5 west_gate
             p11 masn        p13 NAS        uplink -> UCG Fiber p3
UCG Fiber    p2 naahmed-linux + SLZB-06U (only shared port)   p4 ** orin ** (459 rx errors)
```
Every camera is on its OWN managed switch port, and masn is on the same switch -- camera<->masn
traffic never touches the gateway. An earlier note here claimed unmanaged switches sat behind
"ports 1, 2, 4"; that came from conflating gateway port numbers with switch port numbers. There are
none near the cameras, which **kills the STP hypothesis** that rested on them.

**The event log is NOT reachable via API on this firmware** (UniFi OS 5.1.19). All documented paths
404 or 403 with an `admin` role, not just readonly -- `stat/event`, `stat/alarm`,
`v2/.../system-log`, `v2/.../events|alerts|notifications`. Elevating the account does not help; the
endpoints are gone, not forbidden. **Read the system log in the UI.** Do not re-hunt these paths.
`tools/unifi-events.sh` now reports what the API *does* expose (device uptimes, PoE vs budget,
per-port errors, client-to-port mapping).

**SEPARATE FINDING -- the Orin sits on UCG Fiber port 4, which has 459 rx errors** (every other port
is 0 or 8). Not on the camera path, so not this thread's cause, but it is the box that becomes
must-never-be-down at cutover, and it already threw a CIFS "network is unreachable" mount failure on
2026-08-07. Swap that cable before cutover.

**Not caused by any of the Orin work**: gaps go back to 07-30, before the Orin was flashed. This is
a pre-existing reliability issue on the security system and worth fixing on its own merits --
especially before the Orin becomes must-never-be-down and inherits it.

## 8. Audio recording — WORKING, it is a playback mute (answered 2026-08-08)

Reported as "Frigate does not seem to record audio". It does. Verified on two recording files on
different cameras and days:

```
recordings/2026-08-08/17/driveway/17.15.mp4        index0 hevc video   index1 aac audio 16 kHz mono
recordings/2026-08-08/15/driveway_tele/15.03.mp4   index0 h264 video   index1 aac audio mono
```

Every camera stream carries AAC mono (driveway, front_door, backyard all checked via ffprobe on the
go2rtc restream), and `ffmpeg.output_args.record` is already `preset-record-generic-audio-aac`, which
re-encodes audio rather than dropping it. `preset-record-generic` (no `-audio-`) is the one that
would strip it — do not "simplify" to that.

**The player starts muted because browsers block autoplay with sound.** Click the speaker icon. Not
a Frigate setting, and it is per-browser.

GOTCHA for anyone probing this: `ffprobe` is NOT on `$PATH` in the container. Use the full path,
`/usr/lib/ffmpeg/7.0/bin/ffprobe` on masn (`/usr/lib/ffmpeg/jetson/bin/ffprobe` on the Orin, where
DEFAULT_FFMPEG_VERSION=jetson). Also do not `find` over `/media/frigate` — it is a CIFS mount and
takes minutes; get the path from the `recordings` table instead.

**SEPARATE and still off: `audio.enabled: false`** — that is audio DETECTION (events from speech,
barking, alarms; it also populates `audio_rms`/`audio_dBFS`, which is why both read 0 in stats all
session). Nothing to do with recording. Enabling it is another workload that would land on the Orin,
and deserves its own measured change.

NOTE, non-technical: audio recording is treated differently from video in a number of jurisdictions,
including US states with two-party consent rules, and these cameras cover a driveway and front door.
It is already on and no change is proposed — recorded here so the decision is explicit rather than
accidental.

## 9. Viewing the Frigate UI STARVES detection (measured 2026-08-11)

Reported as "the webpage has been laggy on my Mac". It is, and it costs more than lag.

| | idle | Frigate UI live grid open |
|---|---|---|
| container CPU | 26-28% | **82-86%** |
| det_fps | 25-40 | **10** |
| detector utilisation | ~45% | **19%** |
| skipped_fps | none | **100+ on all six cameras** |
| load average | 5.7 | **12.4** |

Frames are dropped BEFORE the detector -- utilisation falls while skipping soars, so the GPU is
idle and the pipeline is starved. **Watching the cameras degrades their detection.**

**CAUSE: still-image polling, not video.** nginx access log over ~30 s:

```
199  GET /api/<cam>/latest.webp     <-- dominates
 12  GET /live/mse/api/ws
  8  GET /live/jsmpeg/<cam>  (x6)
```

The camera grid polls `latest.webp` about once per second PER CAMERA. Each request grabs the current
frame, resizes and WebP-encodes it in the main process. Six of those a second is the load.

**MITIGATION: click into a single camera instead of sitting on the grid.** Six WebP encodes per
second become one. The grid is fine briefly; leaving it open is what hurts.

**TWO WRONG THEORIES, recorded so they are not re-run:**
1. *"Seven software MPEG-1 (jsmpeg) encoders are the cause."* They exist -- `ffmpeg -f rawvideo
   -video_size 896x512 -i pipe: -f mpegts -s 1260x720 -codec:v mpeg1video` x7 -- and they do
   transcode in software with no NVENC. But measured with the view OPEN they totalled **2.9% CPU**.
   Not the problem. The process list at the bad moment already showed them at 0.9-1.3% each while
   `frigate.process:*` ran at 22-31%; that should have been read the first time.
2. *"WebRTC is failing, forcing the jsmpeg fallback."* A host candidate WAS missing and has been
   added (`go2rtc.webrtc.candidates: 192.168.50.200:8555` before `stun:8555`) -- advertising only a
   STUN candidate genuinely cannot help a LAN client. It is a correct change and worth keeping, but
   it did NOT fix this, because video streaming was never the cost.

Not yet investigated: whether the polling interval is configurable, or whether a single-camera view
still polls the other five.

## Deferred housekeeping

- ~~MQTT broker password rotation~~ — **DONE 2026-08-04.** The leaked password (from an earlier
  session's traceback) is rotated. Done as part of Orin migration Phase 1, because the same change
  moved the broker off loopback-only onto the LAN — which is exactly when "later" stopped being an
  acceptable answer. Old credential verified REJECTED afterwards.

## RESOLVED: wall display Pi hardware H.264 decode (2026-08-18)

Nothing held `/dev/video10`. Cause was the VideoCore memory split, not Chromium:

```
gpu=76M                                       <- firmware default
bcm2835_mmal_vchiq: failed to create component -62 (Not enough GPU mem?)
bcm2835-codec: failed to create component ril.video_decode
```

Each hardware decode component allocates from `gpu_mem`, and five simultaneous streams exhaust
76MB. The firmware refuses the decoder and **Chromium falls back to software silently** -- nothing
in the UI reports it -- then retries forever (112 failures in 30 minutes). The only visible symptom
is an unheld `/dev/video10`, which is why it went unnoticed. CMA was NOT the constraint (301MB of
512MB free).

Fixed with `gpu_mem=256` in `/boot/firmware/config.txt` (see `wallpi-stack/config.txt.snippet`).
After reboot: `gpu=256M`, `/dev/video10` held by chromium, zero codec failures.

**CPU DID NOT IMPROVE: 31.5% busy in software vs 31.9% with hardware decode.** Five small
sub-streams are cheap enough to decode in software that the offload is not measurable here. The
real wins are the headroom and no longer spamming failed allocations -- not a lower number. Costs
~180MB of RAM (3886MB -> 3620MB total), with 2495MB still available.

## RESOLVED: wall display skips were HARDWARE DECODE (2026-08-18)

Brief ~1s video skips on the wall. The user's own observation -- "I started noticing after we moved
to HW decode" -- turned out to be exactly right.

### Measured, not argued

Same tiles, same 4-minute window, 1-SECOND sampling of the burnt-in OSD clock:

```
hardware decode   west_gate 10/239s frozen (4.2%)   driveway 5/239s (2.1%)   -- 15 skips
software decode   west_gate  0/239s frozen (0.0%)   driveway 0/239s (0.0%)   --  0 skips
```

The Pi 4 has ONE video decoder block and was being asked to run five simultaneous H.264 sessions.
Software decode is also slightly CHEAPER here -- 30.4% of 4 cores against 31.9% -- because these
sub-streams are small. The offload bought nothing and cost smoothness.

Fixed with `--disable-accelerated-video-decode` in kiosk.service.

### METHODOLOGY TRAP: a 6-second sampler cannot see a 1-second skip

The first measurement compared frames 6s apart and reported 0.20% -- essentially clean -- which
flatly contradicted what was visible on the screen. It can only detect stalls lasting >= 6s. The
skips are ~1s, so they were invisible. `wallpi-stack/tools/fine.sh` samples at 1s and is the tool
to use for this class of problem.

### Ruled out along the way

- **The source.** go2rtc sent data continuously in all 44 of 44 twenty-second windows across all six
  streams. Cameras, go2rtc and the Orin are not involved.
- **The network.** -49 dBm client-side, 433 Mbit/s, 0% packet loss over 60 pings, 6% channel
  utilisation, zero interface errors.
- **DFS radar.** Proposed as the leading theory and DISPROVEN: no radar message in the controller
  log, no channel change in over 2 hours of monitoring, and wallpi held one continuous association
  for 7592s. `tools/wifi-channel-watch.py` still runs and is harmless to leave in place.

### Side finding: gpu_mem=256 was papering over a leak

With gpu_mem back at 76 and a FRESH BOOT, hardware decode worked fine -- the same 76MB that had
been failing earlier. Those failures began 19 minutes after boot, following several kiosk restarts,
which points at decode components not being released across restarts rather than the pool being too
small. Moot now the decoder is unused, but do not treat 256 as the fix if this is ever revisited.
gpu_mem is back to 76, returning ~180MB of RAM.

### Unrelated: the IQAir AirVisual Pro is flapping

`Fn-Link Technology Limited` on MASN 2.4 GHz reassociates every ~40s at -46 dBm, bouncing between
both APs. Not coverage, and nothing to do with the wall -- but it floods the client event log, which
is what made that log unreadable while looking for radar events, and wastes airtime on a 2.4 GHz
band already at 71% utilisation. Usually fixed by pinning the device to one AP or disabling
fast-roaming/band-steering for it.

## Wall display moved: 2560x1440 monitor, and a WiFi latency oddity (2026-08-19)

The Pi was relocated to its wall position and a DIFFERENT MONITOR attached: **2560x1440**, not the
3840x2160 PG32UCDM it was built against.

### What that broke, and what fixed it

- **Every tile-watchdog region.** They are absolute pixel coordinates; a display change invalidates
  all of them. Rescaled by 2/3 and re-verified by cropping each one and looking at it.
- **The info panel overflowed into the camera tile below.** Font sizes were fixed px tuned for a
  2160px-tall panel. **All info-panel typography is now in `vh`**, so it scales with whatever
  display is attached. Anything left in px will break at the next monitor swap.
- **The status tiles still overflowed** even at smaller type, because HA tile cards carry an
  intrinsic minimum height. They are now ONE ROW OF FOUR instead of 2x2.
- **The prayer table lost its styling** -- HA's own markdown table rules outrank a bare `table`
  selector. Qualified as `table, .content table, ha-markdown table` and it wins again.

### The WiFi latency oddity -- real, understood in symptom, NOT the cause of buffering

At this position the link shows a strict repeating pattern to the FIRST HOP (the AP):

```
2ms, 104ms, 104ms, 1.5ms, 104ms, 107ms, ...    two of every three packets delayed ~104ms
avg 55ms, max 270ms, mdev 51ms, 0% packet loss, -59 dBm, tx failed 0
```

Established by measurement:
- **Not the Pi's load** -- identical with the kiosk STOPPED and no video decoding at all.
- **Not client power save** -- `iw set power_save off` and an off/on/off toggle change nothing.
- **Only a full reassociation clears it** (`nmcli con up`), and it stays clean for ~7 minutes before
  drifting back.

**IT DOES NOT MEASURABLY AFFECT THE VIDEO.** Stall rate is 0.22% with latency at 3ms and 0.22% with
it at 64ms -- identical. An earlier 4.47% reading was the streams still settling after the move
(backyard was 62s behind at the time), not the network.

WiFi power save is now disabled in the connection profile anyway (setup-kiosk.sh applies it). It is
harmless and did improve latency temporarily, but it should NOT be described as the fix for
buffering -- that claim was made prematurely and the controlled comparison disproves it.

Mechanism still unknown. Next candidates if it ever does matter: UAPSD on the SSID (UniFi exposes a
per-WLAN toggle), or simply Ethernet at the wall position.

## Wall display "buffering" is DROPPED FRAMES, and the Pi is browning out (2026-08-19)

### It is not buffering. Measured directly, not inferred.

`wallpi-stack/tools/video-stats.py` attaches to the kiosk over the DevTools protocol and reads what
the browser itself reports for every <video>: `waiting`/`stalled` events, dropped-vs-total frames,
readyState and buffer depth. Across every configuration tried:

```
waiting: 0    stalled: 0    readyState: 4 (HAVE_ENOUGH_DATA)    ~1s buffered ahead
```

**Zero rebuffering events, ever.** The network delivers every frame on time. What is visible as
"buffering" is FRAMES BEING DROPPED AT RENDER TIME.

NOTE: the video elements live inside advanced-camera-card's SHADOW DOM, so
`document.querySelectorAll('video')` finds nothing -- the tool walks shadow roots.

### Drop rates by configuration (90s samples)

```
source fps   decode      driveway   front_door   gates      backyard
10 fps       software        3.0%         0.3%   0.7/0.2%       0.2%
20/15 fps    software       15.9%         9.8%   4.2/4.3%       5.4%
15 fps       software       13.6%         8.8%   3.7/4.0%      13.0%
15 fps       HARDWARE       27.1%        23.2%  20.2/5.7%      13.0%
```

Hardware decode is roughly TWICE as bad as software, confirming the earlier finding with a far
better instrument. Software decode stays.

### THE LIKELY ROOT CAUSE: under-voltage

```
vcgencmd get_throttled -> 0x50000
   bit 16: UNDER-VOLTAGE has occurred
   bit 18: THROTTLING has occurred
```

Not thermal -- 51 C, nowhere near the 80 C limit. The Pi has been browning out at its new location,
and under-voltage throttles CPU and GPU, which drops frames exactly like this. **Check the power
supply and cable first** (official 5V/3A USB-C; long or thin cables are the usual cause). Clear the
sticky flags by fully power-cycling, then re-check with `vcgencmd get_throttled` -- 0x0 means fixed.

### Where it stands

Left at 15 fps sources with software decode. 10 fps had far fewer drops but was visibly choppy,
which is what prompted this. Re-measure with `tools/video-stats.py 90` after the power is sorted,
before changing anything else -- the frame rate may well be fine once the Pi stops throttling.

## Wall display stutter: THE POWER SUPPLY (2026-08-19)

**The user's observation cracked this**: it was smooth on the 4K panel yesterday and started
stuttering on the 2560x1440 panel today. That inverts the compute explanation -- 4K is 2.25x MORE
compositing work, and the videos were upscaled harder there too. Something else changed with the
move, and it was power.

### Caught in the act

Sampling `vcgencmd get_throttled` every 2s for 5 minutes:

```
12:06:54  ACTIVE: 0x50005  arm=600MHz
12:08:10  ACTIVE: 0x50005  arm=600MHz
12:09:12  ACTIVE: 0x50005  arm=600MHz
12:10:09  ACTIVE: 0x50005  arm=600MHz
4 events in 150 samples; sticky flags 0x50000
```

`0x50005` sets bit 0 (UNDER-VOLTAGE NOW) and bit 2 (CURRENTLY THROTTLED). **The ARM clock collapses
from 1500MHz to 600MHz** -- 40% of normal -- about once every 75 seconds. A renderer already running
near one core's limit drops a burst of frames every time that happens.

At the desk the Pi read `throttled=0x0`. At the wall it browns out. Same Pi, same software.

### CORRECTION

An earlier entry said a better PSU "will not fix the renderer saturation", based on a 30-SECOND live
sample that happened to fall between events. That was wrong, and the sampling was too short for the
event rate. The renderer being busy is the baseline; the STUTTER is the brownouts.

**RESOLVED 2026-08-19: IT WAS THE USB-C CABLE.** An Anker cable that fast-charges a phone was
browning out the Pi; a UGREEN cable fixed it outright:

```
                 before (Anker)      after (UGREEN)
sticky flags     0x50005             0x0
arm clock        600 MHz             1500 MHz
brownouts        90 of 90 samples    0 of 90
CPU busy         84.5%               34.5%
```

**A cable that fast-charges a phone proves nothing for a Pi 4.** Phone fast charging negotiates
higher voltage and LOWER current (9V/2A), where cable resistance barely matters. The Pi 4 pulls up
to 3A at a fixed 5V, so the same resistance costs three times the voltage drop -- 0.2 ohm round trip
is 0.6V, landing under the ~4.63V threshold. Use the shortest, thickest cable available, and note
the official supply outputs 5.1V specifically to leave margin for this.

**UPDATE (superseded by the above): it went from intermittent to CONTINUOUS.** 90 of 90 samples over 3 minutes
showed `0x50005` with the ARM clock pinned at 600MHz -- the Pi now runs permanently at 40% speed,
not in bursts. Temperature 51 C, so not thermal. No software change can compensate for losing more
than half the CPU, and this is why the wall stayed choppy after every tuning attempt.

FIRST THING TO CHECK: what the Pi is actually plugged into. A monitor USB port, a hub, or a phone
charger supplies well under what a Pi 4 needs (up to 3A) and produces exactly this. It ran clean at
the desk on its old supply.

**A proper 5V/3A supply and a short, thick USB-C cable is the fix.** Verify with
`vcgencmd get_throttled` -- it must read `0x0` after a full power cycle -- then re-measure with
`wallpi-stack/tools/video-stats.py 90`.

### Method note

Intermittent faults need sampling matched to the event rate. One 30-second look said "not
throttling" and sent the investigation down the wrong path for an hour. The 5-minute sample found it
immediately.

## The wall's ceiling is Chromium's RENDERER THREAD (2026-08-19)

Cameras are back at 10 fps, at the user's request -- 10 fps looked fine on the old 4K panel.

### The bottleneck, measured

```
94.9% of one core   --type=renderer      <-- saturated
21.2% of one core   --type=gpu-process
 8.6% of one core   browser/main
```

Chromium composites in a SINGLE renderer thread. Five live video layers saturate one Pi 4 core, and
whatever it cannot paint in time is dropped. This explains every earlier observation at once: more
fps meant more drops, hardware decode was WORSE (extra copies through the same thread), and drops
persisted even at 10 fps.

### Things tried that did NOT move it

```
                                       driveway  front_door  backyard   renderer
10fps, software decode                    11.6%        6.6%      5.5%      94.9%
  + GPU rasterization/zero-copy            7.3%        5.5%      7.2%      95.1%
  + output dropped to 1920x1080            8.8%        9.5%      8.3%      87.3%
```

GPU flags were REMOVED after retesting on healthy power: driveway 9.1% without them against 10.0%
with, which is inside run-to-run variance. They only appeared to help while the Pi was browning out. **Output resolution barely matters** -- so this is a
single-core compute ceiling, not pixel count and not decode. Run-to-run variance is wide (5-12%),
which is what being right at the edge looks like.

### Under-voltage is real but is NOT the current cause

`vcgencmd get_throttled` = `0x50000`: under-voltage and throttling HAVE occurred since boot. But
sampled live, the ARM clock holds 1500MHz, core voltage is steady and temperature is ~49 C, with no
active throttle bits. A better PSU is still worth fitting (the flags are real), but it will not fix
the renderer saturation.

### Where to go if 10 fps still looks wrong

1. **Fewer tiles.** Four cameras instead of five is a straight ~20% cut in compositing work.
2. **Composite server-side.** The Orin has NVENC and spare capacity: ffmpeg `xstack` the five
   sub-streams into ONE 1080p stream, and the Pi renders a single video element instead of five.
   That removes almost all of the renderer's work and is the architecturally right fix for a Pi 4.
3. **A Pi 5**, which has substantially better single-core performance.

Do not spend more time on frame rates, decode paths or resolutions -- all three have been measured
and none of them is the constraint.
