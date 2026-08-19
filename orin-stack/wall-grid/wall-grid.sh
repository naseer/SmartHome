#!/usr/bin/env bash
# Composite the five camera sub-streams into ONE 1080p stream, entirely on Jetson hardware.
#
# WHY: the wall Pi's ceiling is Chromium's renderer thread, pegged at ~98% of one core compositing
# five live video layers. Rendering ONE layer removes almost all of that, and any additional
# display then costs nothing but bandwidth.
#
# Every stage runs on dedicated silicon, NOT the GPU:
#     nvv4l2decoder -> NVDEC     nvcompositor -> VIC     nvv4l2h264enc -> NVENC
# That matters because GR3D already sits at 81-98% for the three yolov9s detectors. A CUDA or GL
# compositor would compete with detection; the VIC does not. Measured cost: 18% of ONE core,
# 1.5% of the 12-core Orin.
#
# Sources come from go2rtc on 127.0.0.1:8554 (published by the frigate container), so this reuses
# the existing camera connections instead of opening five more to the cameras.
#
# Layout mirrors the wall and LEAVES THE TOP-RIGHT CELL BLACK, for Home Assistant's info panel to
# overlay on top:
#     driveway 1280x720 @ 0,0        [ black 640x360 @ 1280,0  = info panel ]
#     west_gate 640x360 @ 1280,360
#     backyard 640x360 @ 0,720   east_gate 640x360 @ 640,720   front_door 640x360 @ 1280,720
set -uo pipefail

R="${GRID_SRC:-rtsp://127.0.0.1:8554}"
BITRATE="${GRID_BITRATE:-4000000}"
FPS="${GRID_FPS:-10}"
# Where the composited stream is served. go2rtc pulls this from inside the frigate container.
PORT="${GRID_PORT:-8099}"

# NO videorate. Asking videorate for 10fps DUPLICATED frames rather than producing unique ones:
# measured 33 of 57 consecutive frames essentially identical (median 13 changed pixels) while a
# single camera over the same window changed on 50 of 51 frames (median 375). The output rate has
# to be negotiated on the COMPOSITOR's src pad so it composites at that rate, instead of being
# rate-converted afterwards.
#
# leaky=downstream: if one camera hiccups, drop its frames rather than stalling the whole grid.
src() {
  echo "rtspsrc location=$1 protocols=tcp latency=200 ! rtph264depay ! h264parse ! nvv4l2decoder \
        ! queue max-size-buffers=8 ! comp.sink_$2"
}

exec gst-launch-1.0 -e \
  nvcompositor name=comp \
    sink_0::xpos=0    sink_0::ypos=0   sink_0::width=1280 sink_0::height=720 \
    sink_1::xpos=1280 sink_1::ypos=360 sink_1::width=640  sink_1::height=360 \
    sink_2::xpos=0    sink_2::ypos=720 sink_2::width=640  sink_2::height=360 \
    sink_3::xpos=640  sink_3::ypos=720 sink_3::width=640  sink_3::height=360 \
    sink_4::xpos=1280 sink_4::ypos=720 sink_4::width=640  sink_4::height=360 \
  ! "video/x-raw(memory:NVMM),width=1920,height=1080" \
  ! nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" \
  ! nvv4l2h264enc bitrate="$BITRATE" iframeinterval="$FPS" idrinterval="$FPS" insert-sps-pps=true \
  ! h264parse ! mpegtsmux ! tcpserversink host=0.0.0.0 port="$PORT" recover-policy=keyframe \
      sync-method=latest-keyframe sync=false \
  $(src "$R/driveway_sub" 0) \
  $(src "$R/west_gate_sub" 1) \
  $(src "$R/backyard_sub" 2) \
  $(src "$R/east_gate_sub" 3) \
  $(src "$R/front_door_sub" 4)
