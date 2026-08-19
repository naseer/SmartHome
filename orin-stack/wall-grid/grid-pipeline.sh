# Same VIC pipeline but without h264parse (which lives in gstreamer1.0-plugins-bad).
R=rtsp://127.0.0.1:8554
src() { echo "rtspsrc location=$1 protocols=tcp latency=200 ! rtph264depay ! nvv4l2decoder ! queue ! comp.sink_$2"; }
gst-launch-1.0 -e \
  nvcompositor name=comp \
    sink_0::xpos=0    sink_0::ypos=0   sink_0::width=1280 sink_0::height=720 \
    sink_1::xpos=1280 sink_1::ypos=360 sink_1::width=640  sink_1::height=360 \
    sink_2::xpos=0    sink_2::ypos=720 sink_2::width=640  sink_2::height=360 \
    sink_3::xpos=640  sink_3::ypos=720 sink_3::width=640  sink_3::height=360 \
    sink_4::xpos=1280 sink_4::ypos=720 sink_4::width=640  sink_4::height=360 \
  ! "video/x-raw(memory:NVMM),width=1920,height=1080" ! nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" \
  ! nvv4l2h264enc bitrate=4000000 iframeinterval=10 insert-sps-pps=true \
  ! fakesink sync=false \
  $(src $R/driveway_sub 0) $(src $R/west_gate_sub 1) $(src $R/backyard_sub 2) \
  $(src $R/east_gate_sub 3) $(src $R/front_door_sub 4)
