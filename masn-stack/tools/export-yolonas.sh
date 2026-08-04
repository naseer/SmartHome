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

# Clear any partial artifact from a failed run so a stale file can't be mistaken
# for a good export (or silently deployed).
rm -f "$OUT_DIR/yolo_nas_s.onnx"

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

    # CPU-only torch: super-gradients would otherwise drag in the ~2.5 GB CUDA wheels,
    # which are useless here (export runs on CPU).
    #
    # torch is PINNED, and the pin is load-bearing. Current torch routes
    # torch.onnx.export through the dynamo exporter, which needs onnxscript; installing
    # onnxscript upgrades onnx past 1.16, which DELETED onnx.mapping -- and
    # onnx_graphsurgeon (what super-gradients uses to bake NMS into the graph) still
    # calls it. That chain ends in a 1 MB truncated file instead of a model. 2.2.x keeps
    # the legacy TorchScript exporter that super-gradients was actually written against.
    pip install -q torch==2.2.2 torchvision==0.17.2 --index-url https://download.pytorch.org/whl/cpu
    pip install -q git+https://github.com/Deci-AI/super-gradients.git

    # super-gradients depends on plain opencv-python, whose cv2 links against X11
    # (libxcb/libGL) that a slim image has no reason to carry -> ImportError on
    # 'import cv2'. The headless wheel is the same cv2 minus the GUI backend.
    #
    # Both wheels own the SAME cv2/ directory, so uninstalling one deletes the other's
    # files and a plain 'install headless' is then a silent no-op ('already satisfied')
    # that leaves NO cv2 at all. Remove both, then install headless fresh.
    pip uninstall -q -y opencv-python opencv-python-headless || true
    pip install -q opencv-python-headless

    # torch 2.2 predates the numpy 2.0 ABI break: torch.tensor(np.array(...)) fails with
    # 'Could not infer dtype of numpy.float32'. super-gradients hits this building the
    # model's baked-in preprocessing. Pin AFTER the other installs so nothing pulls it back up.
    pip install -q 'numpy<2'

    python -c 'import cv2, numpy; print(\"cv2\", cv2.__version__, \"numpy\", numpy.__version__)'

    # find_spec locates the package WITHOUT executing its __init__ -- importing
    # super_gradients for real prints banner/INFO lines that swallow the path.
    SG=\$(python -c \"import importlib.util as u; print(u.find_spec('super_gradients').submodule_search_locations[0])\")
    test -n \"\$SG\" && test -d \"\$SG\"

    sed -i \"s/sghub\\.deci\\.ai/${MIRROR}/g; s/sg-hub-nv\\.s3\\.amazonaws\\.com/${MIRROR}/g\" \
      \"\$SG/training/pretrained_models.py\" \"\$SG/training/utils/checkpoint_utils.py\"
    grep -q '${MIRROR}' \"\$SG/training/pretrained_models.py\"   # weight hosts actually rewritten

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

# Validate the graph HERE rather than discovering it via a Frigate crash-loop.
# frigate/detectors/plugins/openvino.py rejects a yolonas model unless it has
# exactly 1 input, exactly 1 output, and a final output dim of 7
# ([batch, x_min, y_min, x_max, y_max, confidence, class_id]).
import os

import onnx

# A truncated/partial export still leaves a file behind, so check size before shape:
# the real yolo_nas_s graph is ~50 MB, a broken one is ~1 MB.
size_mb = os.path.getsize('/out/yolo_nas_s.onnx') / 1e6
assert size_mb > 10, f'export looks truncated: {size_mb:.1f} MB (expected ~50 MB)'

m = onnx.load('/out/yolo_nas_s.onnx')
onnx.checker.check_model(m)
inputs = [i for i in m.graph.input]
outputs = [o for o in m.graph.output]
assert len(inputs) == 1, f'expected 1 input, got {len(inputs)}'
assert len(outputs) == 1, f'expected 1 output (FLAT_FORMAT), got {len(outputs)}'
last = outputs[0].type.tensor_type.shape.dim[-1].dim_value
assert last == 7, f'expected final output dim 7 (flat format), got {last}'
ishape = [d.dim_value or d.dim_param for d in inputs[0].type.tensor_type.shape.dim]
print(f'OK  input={inputs[0].name}{ishape}  output={outputs[0].name} last_dim={last}')
PY
  "

echo
echo "Wrote: $OUT_DIR/yolo_nas_s.onnx"
ls -lh "$OUT_DIR/yolo_nas_s.onnx"
