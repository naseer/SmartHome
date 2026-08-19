# Server-side wall grid -- DEPLOYED 2026-08-19

The Orin stitches the five camera sub-streams into ONE 1080p stream. Displays render a single video
element instead of five.

## Why

The wall Pi's ceiling was Chromium's RENDERER THREAD, pegged at 94-98% of one core compositing five
live video layers. Chromium composites in a single thread, so this was a hard single-core limit --
frame rate, decode path and output resolution were all measured and none of them was the constraint.

Measured on the Pi, same 10fps sources, before and after:

```
                 renderer CPU     dropped frames (90s)
five videos      94-98% of core   driveway 9.1%, front_door 5.5%, backyard 5.2%
ONE composited   45.5% of core    0.0%   <- zero
```

Cost on the Orin: **2.1% of 12 cores, and no GPU.**

## How

Every stage runs on dedicated silicon, NOT the GPU -- which matters because GR3D already sits at
81-98% for the three yolov9s detectors. A CUDA/GL compositor would compete with detection; the VIC
does not.

```
nvv4l2decoder (NVDEC)  ->  nvcompositor (VIC)  ->  nvv4l2h264enc (NVENC)  ->  mpegtsmux -> tcp :8099
```

Sources are `rtsp://127.0.0.1:8554/<name>_sub` from go2rtc, so this reuses the existing camera
connections rather than opening five more to the cameras. go2rtc then re-publishes the result as the
`wall_grid` stream (see the frigate config), and Home Assistant proxies it to the browser.

Layout leaves the top-right cell BLACK for HA's info panel to overlay:

```
1920x1080:  driveway 1280x720 @ 0,0        [ black 640x360 @ 1280,0 = info panel ]
            west_gate 640x360 @ 1280,360
            backyard 640x360 @ 0,720   east_gate 640x360 @ 640,720   front_door 640x360 @ 1280,720
```

## Install

`./setup-wall-grid.sh` on the Orin. No sudo -- it uses paths the login user owns and the user
crontab, because the Orin requires a password for sudo.

**The keepalive is not optional.** The pipeline EXITS whenever go2rtc goes away: rtspsrc gets EOS
("The server closed the connection"), so any frigate restart kills it silently. Cron restarts it
within a minute; this was verified by killing the pipeline and watching it come back.

## Things that cost an iteration

- **`engine: frigate`, not `generic`.** Generic needs go2rtc's port 1984 published on the LAN, and
  that is an unauthenticated admin API -- exactly what the :5000 lockdown exists to prevent. The
  frigate engine routes through HA's existing proxy, so the browser only ever talks to HA.
- **`id` must be set explicitly.** With no `camera_entity` the card cannot derive one:
  "Could not determine camera id ... may need to set 'id' parameter manually".
- **ffmpeg inside the frigate container is a dead end** despite having NVDEC/NVENC: five
  simultaneous decodes exhaust the nvmpi wrapper ("No empty buffers available to transform").
- **`h264parse` and `mpegtsmux` need `gstreamer1.0-plugins-bad`**, which is not installed by default.
- **nvcompositor outputs RGBA**; nvv4l2h264enc needs NV12, so an `nvvidconv` sits between them.
- Cap the output rate with `videorate`, or the compositor emits ~30fps from 10fps sources.

## tile-watchdog needed a mode change

With one stream every clock freezes together, so the watchdog's usual safety rule ("only act when
some tiles are live and others frozen") would NEVER fire. `mode single_stream` in
`/etc/wall-tiles.conf` tells it all-frozen is actionable. Verified by killing the compositor:
`STALLED: live=0 frozen=5`, then `all tiles healthy again` once cron restored it.
