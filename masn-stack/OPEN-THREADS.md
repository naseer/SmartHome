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

**Detector is now upgraded (thread 2 done), so this is unblocked and is the next step.** Re-enable
detection only first — `automation.frigate_moving_vehicle` is `off`, so no pushes fire — and watch
whether YOLO-NAS still flickers the parked cars. If the flicker is gone the directness gate may be
belt-and-braces rather than load-bearing; keep it either way.

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

## Deferred housekeeping

- ~~MQTT broker password rotation~~ — **DONE 2026-08-04.** The leaked password (from an earlier
  session's traceback) is rotated. Done as part of Orin migration Phase 1, because the same change
  moved the broker off loopback-only onto the LAN — which is exactly when "later" stopped being an
  acceptable answer. Old credential verified REJECTED afterwards.
