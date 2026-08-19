"""Monstree mini6 in, bundle-adjusted sparse point cloud out.

LoMa-B (CUDA) -> LoMa-B matcher -> GLOMAP global SfM -> Caspar/cuDSS bundle
adjustment -> sparse.ply

Run: uv run sfm_demo.py
"""

import urllib.request
from pathlib import Path

import pycolmap

BASE = "https://raw.githubusercontent.com/alicevision/dataset_monstree/master/mini6/"
NAMES = [
    "IMG_1024.JPG",
    "IMG_1026.JPG",
    "IMG_1028.JPG",
    "IMG_1030.JPG",
    "IMG_1032.JPG",
    "IMG_1040.JPG",
]

work_dir = Path("./tmp/monstree_mini6").resolve()
image_dir = work_dir / "images"
image_dir.mkdir(parents=True, exist_ok=True)
for name in NAMES:
    path = image_dir / name
    if not path.exists():
        raw = work_dir / ("raw_" + name)
        print(f"downloading {name}")
        urllib.request.urlretrieve(BASE + name, raw)
        # 12 MP originals blow up the detector's GPU memory: downscale to 800 px
        print(f"downscaling {name} to 800 px")
        bitmap = pycolmap.Bitmap.read(raw, as_rgb=True)
        bitmap.rescale(800, round(800 * bitmap.height / bitmap.width))
        bitmap.write(path)
        raw.unlink()

database_path = work_dir / "database.db"
database_path.unlink(missing_ok=True)
sparse_dir = work_dir / "sparse"
sparse_dir.mkdir(parents=True, exist_ok=True)

extraction_options = pycolmap.FeatureExtractionOptions(
    type=pycolmap.FeatureExtractorType.LOMA_B,
    num_threads=1,  # one image on the GPU at a time
)
# 2048 is the LoMa default; 4096 is the quality-first setting.
extraction_options.loma.max_num_features = 2048
# bf16 needs Ampere or newer; COLMAP probes the ONNX provider and falls back
# to fp32 when the GPU cannot do it. use_fast_resize stays off (the default):
# it buys 2-3x faster extraction on full-resolution input at a small accuracy
# cost, which is not worth it for images already downscaled to 800 px.
extraction_options.loma.use_bf16 = True

pycolmap.extract_features(
    database_path=database_path,
    image_path=image_dir,
    device=pycolmap.Device.cuda,
    extraction_options=extraction_options,
)

matching_options = pycolmap.FeatureMatchingOptions(
    type=pycolmap.FeatureMatcherType.LOMA_B,
)
matching_options.loma.use_bf16 = True

pycolmap.match_exhaustive(
    database_path=database_path,
    device=pycolmap.Device.cuda,
    matching_options=matching_options,
)

reconstruction = pycolmap.global_mapping(
    database_path=database_path,
    image_path=image_dir,
    output_path=sparse_dir,
)[0]

pycolmap.bundle_adjustment(
    reconstruction,
    pycolmap.BundleAdjustmentOptions(backend=pycolmap.BundleAdjustmentBackend.CASPAR),
)
reconstruction.write(sparse_dir / "0")

ply_path = work_dir / "sparse.ply"
reconstruction.export_PLY(ply_path)
print(f"sparse point cloud written to {ply_path}")
