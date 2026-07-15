# Repository guidance

This repository has one purpose: build, validate, and publish two CPython 3.12
GPU `pycolmap` wheels, one for `manylinux_2_34_x86_64` and one for
`win_amd64`. Both use COLMAP 4.1.0, CUDA 12.8.1, cuDNN 9.10.2, cuDSS 0.7.1,
Caspar, and pinned NVIDIA Python runtime dependencies.

Do not add CPU variants, GUI packages, standalone COLMAP archives, local build
environments, or configurable release matrices. Full builds belong in GitHub
Actions and are intentionally fixed to the maintained configurations.

The only dispatchable workflow is `.github/workflows/build-required-pycolmap.yml`.
It calls the reusable Linux and Windows builders, requires both artifacts to
pass, updates `release_wheels.json`, and creates the release. Platform builders
must never publish releases directly.

Important invariants:

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

Before pushing, run:

```bash
bash -n .github/scripts/build_manylinux_wheel.sh
python3 -m py_compile .github/scripts/*.py scripts/*.py wheel_redirect.py
python3 -m json.tool vcpkg.json >/dev/null
python3 -m unittest discover tests
git diff --check
```
