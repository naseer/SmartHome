# Open threads — cameras / notifications / detector

Portable, git-tracked record of the camera-stack work that is **in progress or deliberately paused**, so
any session (including one running on masn) can pick it up without prior context. High-level status lives
in `../AGENTS.md`; this file is the detail. Last updated 2026-08-04.

## Frigate — current live state

OpenVINO on the HD 630 iGPU, model `ssdlite_mobilenet_v2` (300x300, coco), **6 cameras + the TrackMix
tele lens** via go2rtc, 24/7 continuous recording to the NAS, **PERSON detection only**. Config:
`frigate/config/config.yml`.

## 1. Vehicle detection + notifications — DISABLED, with a fix kept for later

**Disabled 2026-08-02.** The weak ssdlite model spawned a flurry of false *moving-car* alerts. Root cause:
two adjacent **parked** cars' boxes oscillate between two fixed positions (the detector conflates them),
fabricating a steady 5-11 km/h *estimated* speed. Neither the instantaneous `speed_threshold` (single-frame
spikes) nor `average_estimated_speed` (inflated by the repeated spikes) separates flicker from a real car.

**The robust discriminator is trajectory DIRECTNESS** = net displacement (start→end) / total path length.
Real cars ~0.99-1.0 (straight down the lane); flicker ≤0.13 (oscillates in place). Only knowable from
`data.path_data` (the centroid track), which Frigate populates ~8 s after lane entry.

Kept in the repo, disabled, ready to re-enable once the detector is upgraded:

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

## 2. Detector upgrade (unblocks bringing vehicles back)

The ssdlite model is too weak. Options evaluated:

- **Coral TPU for the Dell** — REJECTED for accuracy: fast, but runs the SAME small model class, so NO
  accuracy gain. Doesn't solve the flicker.
- **YOLO-NAS / YOLOv9 on OpenVINO (free swap on the Dell)** — better architecture, `model_type: yolonas`
  runs on OpenVINO. The HD 630 has ~5x headroom measured (~9.47 ms inference, ~21.8 inf/sec at load,
  ~20% util, 0 skipped) → a bigger model fits. Zero-cost option.
- **Frigate+ ($50/yr)** — model TUNED to your own cameras (12 trainings/yr), `model_type: yolonas` on
  OpenVINO. Best accuracy-per-effort if staying on the Dell.
- **Migrate Frigate to the Jetson Orin** — user is LEANING here (matches the plan's "heavy AI on the
  Orin" design). "Using the Orin" = moving the whole Frigate container (detectors run in-process, not as a
  remote service). Two gotchas: (a) mosquitto binds `127.0.0.1` on masn → must be LAN-exposed for a
  cross-box Frigate; (b) Frigate's `:5000` API/auth is localhost-only too. Orin is OWNED but NOT YET
  FLASHED (JetPack/L4T needed).

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

## Deferred housekeeping

- MQTT broker password rotation — a password leaked in a traceback (an earlier session); user said "later".
