# COLMAP Build v4.1.1

This release provides GPU-accelerated builds of the official COLMAP 4.1.1 patch
release for Windows and Linux, together with matching pycolmap wheels. All CUDA
archives include Caspar GPU bundle adjustment.

The COLMAP source is byte-identical to the upstream `4.1.1` tag (commit
`a0d785fb`) and is stamped as `4.1.1`. Each artifact is accompanied by a
`build_info.json` provenance record documenting the source commit, toolchain,
CUDA and cuDSS versions, and enabled feature flags. A `SHA256SUMS.txt` file
covering every published asset is included.

Users of v4.1.0 are advised to upgrade. Release 4.1.1 resolves a significant
regression in feature-matching throughput introduced in 4.1.0.

## Changes in COLMAP 4.1.1

### Bug fixes

- Restored feature-matching performance. Release 4.1.0 introduced a
  process-global OpenMP critical section in `RANSAC` and `LORANSAC` that reduced
  matching throughput by approximately 4–6x.
- Corrected rescaling of previously undistorted images when `max_image_size` is
  specified.
- Restored missing SVG icons in the distributed Windows binaries.
- Corrected the Caspar CUDA build under MSVC forced includes.
- Corrected glog color-support version detection.
- Corrected typographical errors in a user-facing help string and in the FAQ.

### Improvements

- The mapper database is now loaded lazily rather than at GUI startup,
  eliminating a redundant read when opening the graphical interface or a project.
- User-interface icons are tinted to the active palette, improving legibility
  under dark themes.
- Image and point viewer metadata is displayed even when the corresponding
  source images are absent from disk.
- The Caspar build now terminates early with an explicit diagnostic on CUDA
  architectures below 7.0.

### Breaking changes

Upstream has renamed the misspelled pycolmap enumeration
`GPSTransfromEllipsoid` to `GPSTransformEllipsoid`. The previous name has been
removed without a backwards-compatible alias. Dependent code must be updated:

```python
# Releases up to and including 4.1.0
pycolmap.GPSTransfromEllipsoid

# Release 4.1.1 onward
pycolmap.GPSTransformEllipsoid
```

Although a rename of this nature is atypical for a patch release, this behaviour
corresponds to the upstream 4.1.1 tag.

Refer to the upstream COLMAP 4.1.1 changelog for the complete list of changes.

## Package matrix

### COLMAP archives (8)

| Platform | Variants |
| --- | --- |
| Ubuntu 22.04 | `CPU`, `CUDA-Caspar`, `CUDA-cuDSS-Caspar` |
| Windows | `CPU`, `CUDA-Caspar`, `CUDA-cuDSS-Caspar`, `CUDA-Caspar-GUI`, `CUDA-cuDSS-Caspar-GUI` |

### pycolmap wheels (55)

Wheels are provided for Python 3.10 through 3.14, on Windows (`win_amd64`) and
Linux (`manylinux_2_35_x86_64`).

| Platform | Variants |
| --- | --- |
| Windows | `+cpu`, `+cuda`, `+cuda.cudss` |
| Linux | `+cpu`, `+cuda`, and bundled CUDA runtimes `+cu128`, `+cu130`, `+cu131`, each with a `.cudss` variant |

Wheels marked `.bundled` include the CUDA runtime libraries within the wheel.

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

Select the wheel corresponding to the required Python version, platform, and
CUDA runtime, then install it directly:

```bash
pip install pycolmap-4.1.1+cuda-cp312-cp312-win_amd64.whl
```

## Caspar bundle adjustment

Caspar GPU bundle adjustment is selected via `--BundleAdjustment.backend CASPAR`
in the `colmap bundle_adjuster` command, and via
`pycolmap.BundleAdjustmentBackend.CASPAR` in the CUDA wheels:

```python
import pycolmap

assert pycolmap.BundleAdjustmentBackend.CASPAR == pycolmap.BundleAdjustmentBackend("CASPAR")
opts = pycolmap.BundleAdjustmentOptions()
opts.backend = pycolmap.BundleAdjustmentBackend.CASPAR
opts.caspar.gpu_index = "0"
```

Caspar requires a CUDA architecture of 7.0 or newer. Release 4.1.1 reports
unsupported architectures as an explicit build-time error.

A deterministic validation script is provided in the repository:

```bash
python scripts/validate_caspar_sample.py --colmap /path/to/colmap --require-pycolmap
```

The script generates a COLMAP text model, executes `colmap bundle_adjuster
--BundleAdjustment.backend CASPAR`, and asserts that the reprojection error
improves.

## Runtime requirements

- CPU packages do not require an NVIDIA GPU.
- CUDA packages require an NVIDIA driver compatible with the CUDA runtime of the
  selected asset.
- Windows CUDA COLMAP packages bundle the required CUDA runtime libraries.
- Linux COLMAP CUDA archives require compatible NVIDIA runtime support on the
  host system.
- Linux pycolmap wheels identified by `.bundled` include CUDA runtime libraries
  within the wheel.
- Variants identified by `cuDSS` provide cuDSS sparse-solver support for Ceres
  bundle adjustment.
- Linux binaries in this release are built with OpenBLAS runtime CPU dispatch and
  therefore do not require any specific instruction-set extension beyond the
  x86-64 baseline.
