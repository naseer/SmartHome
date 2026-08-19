# The Orin -> Pi wall streamer: how it is wired, and how to check each hop

Built 2026-08-19. This is the record of what was changed, where, and how to verify it.

## Why it exists

The wall Pi rendered five separate `<video>` elements. Chromium composites in a SINGLE renderer
thread, which sat at 94-98% of one Pi 4 core and dropped ~9% of frames on the busiest tile. Frame
rate, decode path (hardware vs software) and output resolution were each measured and NONE of them
was the constraint -- it was single-core compositing. Moving the compositing to the Orin means the
Pi paints one video layer instead of five.

```
                              five videos      one composited stream
Pi renderer thread            94-98% of core   45.5% of core
dropped frames over 90s       up to 9.1%       0.0%
cost on the Orin              --               2.1% of 12 cores, no GPU
```

## The data path, hop by hop

```
5 Reolink cameras
  |  RTSP sub-streams, 10fps, 1s GOP
  v
go2rtc (inside the frigate container on the Orin)
  |  rtsp://127.0.0.1:8554/<name>_sub          <- published on the host, so the host can read it
  v
wall-grid.sh   (HOST, GStreamer, all dedicated silicon)
  |  nvv4l2decoder (NVDEC) -> nvcompositor (VIC) -> nvv4l2h264enc (NVENC) -> mpegtsmux
  |  MPEG-TS over TCP on 0.0.0.0:8099
  v
go2rtc again, as the stream `wall_grid`
  |  ffmpeg:tcp://172.18.0.1:8099#video=copy   <- 172.18.0.1 is the stack_default bridge gateway;
  |                                               a container cannot reach a host port via 127.0.0.1
  v
Home Assistant, via the Frigate integration's proxy   (/api/frigate/<client_id>/mse/...)
  |
  v
Chromium on the wall Pi -- ONE advanced-camera-card, MSE
```

**Nothing new is exposed on the LAN.** The browser talks only to Home Assistant. Using the card's
`generic` engine instead would have required publishing go2rtc's port 1984, which is an
UNAUTHENTICATED admin API -- precisely what the `:5000` lockdown exists to prevent.

## What was changed, and where

| Where | Change |
|---|---|
| `orin-stack/wall-grid/wall-grid.sh` | the GStreamer pipeline |
| `orin-stack/wall-grid/setup-wall-grid.sh` | installs it to `/opt/stack/tools/` + user crontab |
| `orin-stack/frigate/config/config.yml` | go2rtc stream `wall_grid` |
| `wallpi-stack/build-wall-dashboard.py` | one grid card instead of five camera cards |
| `wallpi-stack/wall-tiles.conf` | new clock regions + `mode single_stream` |
| `wallpi-stack/tile-watchdog.sh` | understands `mode single_stream` |
| Orin, manually | `sudo apt-get install gstreamer1.0-plugins-bad` (h264parse, mpegtsmux) |

Scheduling uses the USER CRONTAB, not systemd, because the Orin requires a password for sudo.

## Verifying each hop

```bash
# 1. compositor alive on the Orin (expect 1)
ssh nvidia@orin.internal 'pgrep -xc gst-launch-1.0'

# 2. it is serving (expect 1)
ssh nvidia@orin.internal 'ss -ltn | grep -c :8099'

# 3. the stream is real -- expect h264,1920,1080,10/1
ssh nvidia@orin.internal 'docker exec frigate timeout 30 /usr/lib/ffmpeg/7.0/bin/ffprobe -v error \
  -rtsp_transport tcp -i rtsp://127.0.0.1:8554/wall_grid -select_streams v \
  -show_entries stream=codec_name,width,height,avg_frame_rate -of csv=p=0'

# 4. cost on the Orin (expect ~25% of ONE core = ~2% of 12)
ssh nvidia@orin.internal 'P=$(pgrep -x gst-launch-1.0); a=$(awk "{print \$14+\$15}" /proc/$P/stat); \
  sleep 20; b=$(awk "{print \$14+\$15}" /proc/$P/stat); echo "$(( (b-a)/20 ))% of one core"'

# 5. what the Pi's browser actually gets -- expect 1 video, 0 dropped, 0 waiting/stalled
#    (needs --remote-debugging-port=9222 added to kiosk.service temporarily)
wallpi-stack/tools/video-stats.py 90

# 6. the wall itself
wallpi-stack/tools/screenshot.sh wall.png
ssh wallpi 'KIOSK_MIN_UPTIME=0 /usr/local/bin/tile-watchdog.sh'   # silent = all clocks advancing
```

## Failure modes seen, and what they look like

- **The pipeline exits whenever go2rtc goes away.** `rtspsrc` gets EOS -- "The server closed the
  connection" -- so ANY frigate restart kills it silently. The cron keepalive restarts it within a
  minute. This is why the keepalive is required, not decorative.
- **go2rtc shows `wall_grid` with `recv=0.00 MB`** and RTSP 404s: the compositor is not running.
  go2rtc also connects lazily, so 0 bytes with no consumer is normal.
- **All five clocks frozen at once** is a genuine stall here, unlike the five-video layout where it
  meant a display fault. `mode single_stream` in `wall-tiles.conf` tells tile-watchdog that.

## Dead ends -- do not retry

- **ffmpeg inside the frigate container.** It does have NVDEC/NVENC via nvmpi, but five
  simultaneous decodes exhaust its buffers: "No empty buffers available to transform, Frame
  skipped!" followed by "Got 0 size buffer in capture".
- **CUDA/GL compositing.** GR3D already runs at 81-98% for the three yolov9s detectors. The VIC is
  separate silicon and does not compete with them; a GPU compositor would.
- **`engine: generic` on the card.** Needs go2rtc's 1984 published on the LAN. Use `engine: frigate`
  so it routes through HA's existing proxy.

## Gotchas that each cost an iteration

- `h264parse` and `mpegtsmux` live in `gstreamer1.0-plugins-bad`, not installed by default.
- `nvcompositor` outputs RGBA; `nvv4l2h264enc` wants NV12 -- an `nvvidconv` goes between them.
- Without `videorate` the compositor emits ~30fps from 10fps sources, wasting encode and bandwidth.
- The card needs BOTH `engine` and `id` set explicitly when there is no `camera_entity`.
- **Every "0.0% CPU" reading during development was a pipeline that had failed to link.** Confirm a
  filesink capture contains frames (`ffprobe -count_frames`) before believing any cost number.
