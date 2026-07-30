# COLMAP Build v4.1.1

GPU-accelerated builds of the official **COLMAP 4.1.1** patch release for Windows
and Linux, plus matching pycolmap wheels. The CUDA archives include **Caspar GPU
bundle adjustment**.

This is a stable release: the COLMAP source is byte-identical to the upstream
`4.1.1` tag (commit `a0d785fb`) and stamped as `4.1.1`. Every artifact carries a
`build_info.json` provenance record (commit, toolchain, CUDA/cuDSS versions,
feature flags).

Upgrading from `v4.1.0` is recommended — 4.1.1 restores a large feature-matching
performance regression present in 4.1.0.

## What's new in COLMAP 4.1.1

Bug fixes:

- **Feature matching speed restored** — 4.1.0 had a process-global OpenMP
  critical section in `RANSAC`/`LORANSAC` that slowed matching by roughly 4–6x.
- Fixed rescaling of already-undistorted images when `max_image_size` is given.
- Fixed missing SVG icons in the distributed Windows binaries.
- Fixed the Caspar CUDA build with MSVC forced includes.
- Fixed glog color-support version detection.
- Fixed typos in a user-facing help string and the FAQ.

Improvements:

- The mapper database is now loaded lazily instead of at GUI startup, avoiding a
  redundant read when opening the GUI or a project.
- UI icons are tinted to the palette for better dark-theme legibility.
- Image/point viewer metadata is shown even when source images are missing on disk.
- The Caspar build now fails early with a clear error on CUDA architectures below 7.0.

### ⚠️ Breaking change

Upstream renamed the misspelled pycolmap enum `GPSTransfromEllipsoid` to
**`GPSTransformEllipsoid`**. The old name was removed with no backwards-compatible
alias, so any code referencing it must be updated:

```python
# before (4.1.0 and earlier)
pycolmap.GPSTransfromEllipsoid
# after (4.1.1)
pycolmap.GPSTransformEllipsoid
```

This is unusual for a patch release, but it matches the upstream 4.1.1 tag.

See the upstream COLMAP 4.1.1 changelog for the complete list.

## Package matrix

### COLMAP archives (8)

| Platform | Variants |
| --- | --- |
| Ubuntu 22.04 | `CPU`, `CUDA-Caspar`, `CUDA-cuDSS-Caspar` |
| Windows | `CPU`, `CUDA-Caspar`, `CUDA-cuDSS-Caspar`, `CUDA-Caspar-GUI`, `CUDA-cuDSS-Caspar-GUI` |

### pycolmap wheels (55)

- Python `3.10`, `3.11`, `3.12`, `3.13`, `3.14`.
- Windows `win_amd64` and Linux `manylinux_2_35_x86_64`.
- CPU and CUDA wheels for both platforms; Windows CUDA + cuDSS wheels.
- Linux bundled-CUDA-runtime wheels for CUDA `12.8`, `13.0`, and `13.1`,
  including cuDSS variants.

Every artifact ships a `*.build_info.json` provenance sidecar, and a
`SHA256SUMS.txt` covers the full asset set.

## Installation

### COLMAP

Windows:

```powershell
Expand-Archive COLMAP-4.1.1-windows-2022-CUDA-Caspar.zip -DestinationPath C:\Tools\COLMAP
C:\Tools\COLMAP\bin\colmap.exe version
```

Linux:

```bash
unzip COLMAP-4.1.1-ubuntu-22.04-CUDA-Caspar.zip -d ~/tools/colmap
~/tools/colmap/bin/colmap version
```

### pycolmap

Download the wheel matching your Python version, platform, and CUDA/runtime
needs, then install it directly:

```bash
pip install pycolmap-4.1.1+cuda-cp312-cp312-win_amd64.whl
```

## Caspar bundle adjustment

Caspar GPU bundle adjustment is selected with `--BundleAdjustment.backend CASPAR`
in the `colmap bundle_adjuster` command, and through
`pycolmap.BundleAdjustmentBackend.CASPAR` in the CUDA wheels:

```python
import pycolmap

assert pycolmap.BundleAdjustmentBackend.CASPAR == pycolmap.BundleAdjustmentBackend("CASPAR")
opts = pycolmap.BundleAdjustmentOptions()
opts.backend = pycolmap.BundleAdjustmentBackend.CASPAR
opts.caspar.gpu_index = "0"
```

Caspar requires a CUDA architecture of 7.0 or newer; 4.1.1 now reports this as a
clear build-time error rather than failing obscurely.

A deterministic validation script is included in the repository:

```bash
python scripts/validate_caspar_sample.py --colmap /path/to/colmap --require-pycolmap
```

It generates a COLMAP text model, runs `colmap bundle_adjuster
--BundleAdjustment.backend CASPAR`, and asserts that reprojection error improves.

## Runtime notes

- CPU packages do not require an NVIDIA GPU.
- CUDA packages require an NVIDIA driver compatible with the CUDA runtime in the
  selected asset.
- Windows CUDA COLMAP packages bundle the required CUDA runtime DLLs.
- Linux COLMAP CUDA archives expect compatible NVIDIA runtime support on the host.
- Linux `pycolmap` wheels with `.bundled` in the filename include CUDA runtime
  libraries inside the wheel.
- `CUDA-cuDSS` variants add cuDSS sparse-solver support for Ceres bundle
  adjustment.
