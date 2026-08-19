# Server-side wall grid (WORK IN PROGRESS -- not deployed)

Stitch the five camera sub-streams into ONE video on the Orin, so any display renders a single
video element instead of five. The wall Pi's limit is Chromium's renderer thread, pegged at ~98% of
one core compositing five live layers; one layer removes almost all of that. It also means extra
displays cost nothing beyond bandwidth.

## Why this shape

The Orin has three DEDICATED hardware blocks, all separate from the CUDA cores the detectors use:

```
nvv4l2decoder  -> NVDEC   decode 5 sub-streams
nvcompositor   -> VIC     scale + composite   (Video Image Compositor)
nvv4l2h264enc  -> NVENC   encode one 1080p stream
```

All three are present on this box. **This matters because GR3D (the GPU) already runs at 81-98%**
for the three yolov9s detectors -- a GPU/CUDA compositing approach would fight them, and the VIC
path does not.

Source is `rtsp://127.0.0.1:8554/<name>_sub` from go2rtc (8554 is published on the host), so this
reuses the existing camera connections rather than opening new ones.

Layout mirrors the wall and LEAVES THE TOP-RIGHT CELL BLACK for HA's info panel to overlay:

```
1920x1080:  driveway 1280x720 @ (0,0)      [black 640x360 @ (1280,0) = info panel]
            west_gate 640x360 @ (1280,360)
            backyard 640x360 @ (0,720)   east_gate 640x360 @ (640,720)
            front_door 640x360 @ (1280,720)
```

## BLOCKED ON

`sudo apt-get install gstreamer1.0-plugins-bad` on the Orin -- it provides `h264parse` and
`mpegtsmux`. The Orin requires a sudo password, so this needs a human. Without h264parse the
pipeline builds but has not been proven to emit frames.

## What was ruled out

**ffmpeg inside the frigate container** (which does have NVDEC/NVENC via nvmpi) fails with five
simultaneous decodes:

```
No empty buffers available to transform, Frame skipped!
Got 0 size buffer in capture
```

The nvmpi wrapper runs out of buffers. Not worth pursuing over the GStreamer/VIC path.

## Load estimate -- NOT YET VERIFIED

Expected well under one core, since decode, composite and encode all run on dedicated silicon and
userspace only shuffles buffer handles. **Every CPU measurement taken so far read 0.0% while the
pipeline was actually failing to link**, so treat the estimate as unproven until the output file is
confirmed to contain frames. Verify with `ffprobe -count_frames` on a filesink capture, not by
whether the process is alive.

## Serving it once it works

Add to go2rtc as a stream the Pi can consume, then replace the five camera cards in
`wallpi-stack/build-wall-dashboard.py` with one card pointing at it, keeping the info panel overlaid
on the black cell.
