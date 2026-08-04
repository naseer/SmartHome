#!/usr/bin/env bash
# Export a Frigate-compatible YOLO-NAS-S ONNX (COCO pretrained, 320x320).
#
# This is a local, reproducible replacement for Frigate's official Colab notebook
# (notebooks/YOLO_NAS_Pretrained_Export.ipynb). Same model, same export params --
# we just run it in a throwaway python:3.11 container instead of a browser, so the
# artifact is auditable and the step can be repeated after a rebuild.
#
# Why 3.11: super-gradients (Deci-AI, now unmaintained) does not work on 3.12+.
# Why the sed: Deci's model-weight hosts (sghub.deci.ai / sg-hub-nv.s3) are dead;
# upstream's notebook rewrites them to the surviving CloudFront mirror.
#
# Output: ./yolo_nas_s.onnx (~50 MB) in $OUT_DIR. One-time; takes ~10-15 min
# (mostly the torch download). Consumes ~4 GB of scratch inside the container.
#
# Usage: ./export-yolonas.sh [OUT_DIR]     (default: current directory)

set -euo pipefail

OUT_DIR="$(readlink -f "${1:-$PWD}")"
mkdir -p "$OUT_DIR"

MIRROR='d2gjn4b69gu75n.cloudfront.net'

docker volume create yolonas-pip-cache >/dev/null

docker run --rm \
  -v "$OUT_DIR:/out" \
  -v yolonas-pip-cache:/root/.cache/pip \
  -w /work \
  python:3.11-slim \
  bash -euxc "
    # slim has no git, and super-gradients is only installable from source.
    apt-get -qq update && apt-get -qq install -y --no-install-recommends git >/dev/null

    # CPU-only torch first: super-gradients would otherwise drag in the ~2.5 GB
    # CUDA wheels, which are useless here (export runs on CPU).
    pip install -q torch torchvision --index-url https://download.pytorch.org/whl/cpu
    pip install -q git+https://github.com/Deci-AI/super-gradients.git

    # super-gradients depends on plain opencv-python, whose cv2 links against X11
    # (libxcb/libGL) that a slim image has no reason to carry -> ImportError on
    # 'import cv2'. The headless wheel is the same cv2 minus the GUI backend.
    pip uninstall -q -y opencv-python
    pip install -q opencv-python-headless

    SG=\$(python -c 'import super_gradients,os;print(os.path.dirname(super_gradients.__file__))')
    sed -i \"s/sghub\\.deci\\.ai/${MIRROR}/g; s/sg-hub-nv\\.s3\\.amazonaws\\.com/${MIRROR}/g\" \
      \"\$SG/training/pretrained_models.py\" \"\$SG/training/utils/checkpoint_utils.py\"

    python - <<'PY'
from super_gradients.common.object_names import Models
from super_gradients.conversion import DetectionOutputFormatMode
from super_gradients.training import models

model = models.get(Models.YOLO_NAS_S, pretrained_weights='coco')

# Export params are upstream's, verbatim. FLAT_FORMAT + baked-in NMS is what
# Frigate's yolonas post-processor expects; 320x320 keeps inference cheap.
model.export(
    '/out/yolo_nas_s.onnx',
    output_predictions_format=DetectionOutputFormatMode.FLAT_FORMAT,
    max_predictions_per_image=20,
    num_pre_nms_predictions=300,
    confidence_threshold=0.4,
    input_image_shape=(320, 320),
)
PY
  "

echo
echo "Wrote: $OUT_DIR/yolo_nas_s.onnx"
ls -lh "$OUT_DIR/yolo_nas_s.onnx"
