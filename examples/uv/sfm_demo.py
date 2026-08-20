# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["pycolmap>=4.2.0.dev0,<4.3"]
#
# [tool.uv]
# prerelease = "allow"
#
# [[tool.uv.sources.pycolmap]]
# url = "https://github.com/flol3622/build_gpu_colmap/releases/download/pycolmap-4.2.0.dev0-cu128-cudss-r1/pycolmap-4.2.0.dev0%2Bcu128.pipcuda.cudss-cp312-cp312-manylinux_2_34_x86_64.whl"
# marker = "sys_platform == 'linux' and platform_machine == 'x86_64'"
#
# [[tool.uv.sources.pycolmap]]
# url = "https://github.com/flol3622/build_gpu_colmap/releases/download/pycolmap-4.2.0.dev0-cu128-cudss-r1/pycolmap-4.2.0.dev0%2Bcu128.pipcuda.cudss-cp312-cp312-win_amd64.whl"
# marker = "sys_platform == 'win32' and platform_machine == 'AMD64'"
# ///
"""Monstree mini6 in, bundle-adjusted sparse point cloud out.

LoMa-B (CUDA) -> LoMa-B matcher -> GLOMAP global SfM -> Caspar/cuDSS bundle
adjustment -> sparse.ply

Runs on a 4 GB card: fp32 LoMa-B loads ~2.2 GB of weights. bf16 halves that
if you are tight on memory -- see below.

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

pycolmap.extract_features(
    database_path=database_path,
    image_path=image_dir,
    device=pycolmap.Device.cuda,
    extraction_options=pycolmap.FeatureExtractionOptions(
        type=pycolmap.FeatureExtractorType.LOMA_B,
        num_threads=1,  # one image on the GPU at a time
        loma=pycolmap.LomaExtractionOptions(
            max_num_features=2048,  # LoMa default; 4096 buys quality
            # Uncomment to halve descriptor weights (~1.2 GB instead of
            # ~2.2 GB). Ampere or newer runs bf16 natively; the bf16 matcher
            # falls back to fp32 on its own when the GPU cannot place it.
            # use_bf16=True,
        ),
    ),
)

pycolmap.match_exhaustive(
    database_path=database_path,
    device=pycolmap.Device.cuda,
    matching_options=pycolmap.FeatureMatchingOptions(
        type=pycolmap.FeatureMatcherType.LOMA_B,
        # loma=pycolmap.LomaMatchingOptions(use_bf16=True),
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
