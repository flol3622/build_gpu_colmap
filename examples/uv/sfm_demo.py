"""Monstree mini6 in, bundle-adjusted sparse point cloud out.

ALIKED (CUDA) -> LightGlue -> GLOMAP global SfM -> Caspar/cuDSS bundle
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
        # 12 MP originals blow up ALIKED's GPU memory: downscale to 800 px
        print(f"downscaling {name} to 800 px")
        bitmap = pycolmap.Bitmap.read(raw, as_rgb=True)
        bitmap.rescale(800, round(800 * bitmap.height / bitmap.width))
        bitmap.write(path)
        raw.unlink()

database_path = work_dir / "database.db"
database_path.unlink(missing_ok=True)
sparse_dir = work_dir / "sparse"
sparse_dir.mkdir(parents=True, exist_ok=True)

pycolmap.extract_features(
    database_path=database_path,
    image_path=image_dir,
    device=pycolmap.Device.cuda,
    extraction_options=pycolmap.FeatureExtractionOptions(
        type=pycolmap.FeatureExtractorType.ALIKED_N16ROT,
        num_threads=1,  # one image on the GPU at a time
    ),
)

pycolmap.match_exhaustive(
    database_path=database_path,
    device=pycolmap.Device.cuda,
    matching_options=pycolmap.FeatureMatchingOptions(
        type=pycolmap.FeatureMatcherType.ALIKED_LIGHTGLUE,
    ),
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
