#!/usr/bin/env bash
# Composite ONLY THE BOTTOM ROW -- backyard | east_gate | front_door -- into one 1920x360 strip.
#
# WHY A HYBRID rather than the full five-way grid (wall-grid.sh): the full grid wins on CPU and
# dropped frames but loses on MOTION, because nvcompositor only re-samples its inputs ~4 times a
# second. That trade is bad for the driveway, which is the 2x2 hero tile and where the motion you
# actually watch happens -- so driveway and west_gate stay as client-side tiles at full frame rate.
#
# The three cells here are the ones that can afford it. Per the mpdecimate measurements in
# README.md, these static scenes already carry only ~3.7 fps of visually distinct content at SOURCE,
# so the compositor's ~4 unique fps ceiling costs them almost nothing. The Pi goes from five video
# layers to three, which is where the renderer-thread saving comes from.
#
# Runs on its own port and its own go2rtc stream so it can coexist with wall-grid.sh for A/B tests.
# DO NOT run both at once in production -- they pull the same sub-streams twice.
set -uo pipefail

R="${GRID_SRC:-rtsp://127.0.0.1:8554}"
BITRATE="${GRID_BITRATE:-3000000}"
FPS="${GRID_FPS:-10}"
PORT="${GRID_PORT:-8098}"

# ASPECT RATIOS DIFFER PER CAMERA and nvcompositor does NOT letterbox -- it stretches the input to
# whatever width/height the sink is given. Feeding all three into identical 640x360 cells would
# squash front_door and stretch backyard. Each cell is handled to match what the wall shows today:
#
#   backyard    1536x576 (2.67:1)  `cover` today -> CROP the centre 1024x576 (16:9), then fill.
#   east_gate    640x360 (16:9)    exact fit, nothing to do.
#   front_door   640x480 (4:3)     `contain` today -> PILLARBOX: 480x360 centred, black either side.
#
# Cropping happens on nvvidconv (VIC), before the compositor, so it costs no GPU. Its left/right/
# top/bottom are ABSOLUTE EDGES in input pixels, not margins.

# $1 = rtsp path, $2 = sink index, $3 = optional "nvvidconv crop" args
src() {
  local conv="nvvidconv"
  [ -n "${3:-}" ] && conv="nvvidconv $3"
  echo "rtspsrc location=$1 protocols=tcp latency=200 ! rtph264depay ! h264parse ! nvv4l2decoder \
        ! queue max-size-buffers=8 leaky=downstream ! $conv ! comp.sink_$2"
}

# NO videorate -- see wall-grid.sh. The rate has to be negotiated on the compositor's SRC pad so it
# composites at that rate, rather than being rate-converted (i.e. frame-duplicated) afterwards.
exec gst-launch-1.0 -e \
  nvcompositor name=comp \
    sink_0::xpos=0    sink_0::ypos=0 sink_0::width=640 sink_0::height=360 \
    sink_1::xpos=640  sink_1::ypos=0 sink_1::width=640 sink_1::height=360 \
    sink_2::xpos=1360 sink_2::ypos=0 sink_2::width=480 sink_2::height=360 \
  ! "video/x-raw(memory:NVMM),width=1920,height=360" \
  ! nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" \
  ! nvv4l2h264enc bitrate="$BITRATE" iframeinterval="$FPS" idrinterval="$FPS" insert-sps-pps=true \
  ! h264parse ! mpegtsmux ! tcpserversink host=0.0.0.0 port="$PORT" recover-policy=keyframe \
      sync-method=latest-keyframe sync=false \
  $(src "$R/backyard_sub"   0 "left=256 right=1280 top=0 bottom=576") \
  $(src "$R/east_gate_sub"  1) \
  $(src "$R/front_door_sub" 2)
