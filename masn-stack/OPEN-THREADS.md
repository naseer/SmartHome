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

## Deferred housekeeping

- ~~MQTT broker password rotation~~ — **DONE 2026-08-04.** The leaked password (from an earlier
  session's traceback) is rotated. Done as part of Orin migration Phase 1, because the same change
  moved the broker off loopback-only onto the LAN — which is exactly when "later" stopped being an
  acceptable answer. Old credential verified REJECTED afterwards.
