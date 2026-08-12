# Repository guidance

This repository has one purpose: build, validate, and publish two CPython 3.12
GPU `pycolmap` wheels, one for `manylinux_2_34_x86_64` and one for
`win_amd64`. Both are maxed-out configurations — COLMAP 4.1.1, CUDA 12.8.1,
cuDNN 9.10.2, cuDSS 0.7.1, Caspar, ONNX Runtime CUDA, and pinned NVIDIA Python
runtime dependencies, with nothing switched off.

Do not add CPU variants, GUI packages, standalone COLMAP archives, local build
environments, or configurable release matrices. Full builds belong in GitHub
Actions and are intentionally fixed to the maintained configurations.

## Cutting a release

The only dispatchable workflow is `.github/workflows/build-required-pycolmap.yml`.
It calls the reusable Linux and Windows builders in parallel, requires both
artifacts to pass, updates `release_wheels.json` on `master`, creates the
requested tag at that exact commit, and marks the GitHub release as latest.
Platform builders must never publish releases directly.

```bash
gh workflow run build-required-pycolmap.yml --ref master -f release_tag=pycolmap-4.1.1-cu128-cudss-r1
```

## Release gates

Each release verifies that:

- CUDA and cuDSS are enabled in the native build.
- Caspar is exported by COLMAP and exposed in the pycolmap API.
- `DOWNLOAD_ENABLED=ON` is retained for automatic ALIKED model downloads.
- Wheel names, tags, metadata, and pinned NVIDIA dependencies are exact.
- NVIDIA runtime libraries are required, not duplicated inside the wheel.
- Linux repair includes the ONNX Runtime CUDA providers and resolves their full
  dependency graph against the installed NVIDIA packages.
- Windows repair produces a clean-installable wheel whose NVIDIA DLLs preload
  successfully before `_core.pyd` is imported.
- A clean environment can import pycolmap and download/open the default
  `aliked-n16rot.onnx` model.

## Invariants

- Build Ceres and COLMAP-for-pycolmap with CUDA, cuDSS, Caspar, and
  `DOWNLOAD_ENABLED=ON`.
- Keep exact NVIDIA runtime requirements in wheel metadata; do not bundle those
  libraries into the pycolmap wheel.
- Preserve ONNX Runtime CUDA providers in the repaired wheel.
- On Windows, register and explicitly preload NVIDIA DLLs before importing
  `_core.pyd`; keep the returned handles alive.
- Validate clean installation/import, the Caspar API, and the default ALIKED
  model download.
- Keep submodules pinned and source changes as small patches under `patches/`.

## Repository layout

| Path | Does what |
| --- | --- |
| `CMakeLists.txt` | Builds pinned Ceres and COLMAP-for-pycolmap with CUDA, cuDSS, Caspar, ONNX |
| `.github/scripts/build_manylinux_wheel.sh` | Builds, repairs, validates the Linux wheel in a PyPA container |
| `.github/workflows/build-windows-pycolmap.yml` | Same, for Windows |
| `.github/workflows/build-required-pycolmap.yml` | Coordinates and publishes the two-wheel release |
| `patches/` | Minimal diffs on top of pinned upstream pycolmap/COLMAP |
| `release_wheels.json`, `wheel_redirect.py` | Pin and serve the released platform wheels |

## Before pushing

```bash
bash -n .github/scripts/build_manylinux_wheel.sh
python3 -m py_compile .github/scripts/*.py scripts/*.py wheel_redirect.py
python3 -m json.tool vcpkg.json >/dev/null
python3 -m unittest discover tests
git diff --check
```
