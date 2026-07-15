# GPU pycolmap wheels

This repository builds and publishes exactly two GPU-enabled `pycolmap` wheels:

| Platform | Wheel |
| --- | --- |
| Linux x86_64, glibc 2.34+ | `pycolmap-4.1.0+cu128.pipcuda.cudss-cp312-cp312-manylinux_2_34_x86_64.whl` |
| Windows x86_64 | `pycolmap-4.1.0+cu128.pipcuda.cudss-cp312-cp312-win_amd64.whl` |

Both target CPython 3.12 and COLMAP 4.1.0 with CUDA 12.8.1, cuDNN 9.10.2,
cuDSS 0.7.1, ONNX Runtime CUDA inference, ALIKED/LightGlue, and the Caspar
bundle-adjustment backend. CUDA, cuDNN, and cuDSS are pinned Python
dependencies, so pip or uv installs the user-space GPU runtime automatically.
Only a compatible NVIDIA driver must already be installed on the machine.

This is not a general COLMAP distribution. It does not produce CPU wheels,
standalone COLMAP archives, GUI packages, or an arbitrary build matrix.

## Install

Install through the repository's redirect package:

```bash
uv add "git+https://github.com/flol3622/build_gpu_colmap"
uv run python -c "import pycolmap; print(pycolmap.__version__)"
```

The redirect backend selects the matching wheel from the latest pinned release
and verifies its size and SHA-256 digest. It never compiles COLMAP locally.

Alternatively, download the matching asset from
[GitHub Releases](https://github.com/flol3622/build_gpu_colmap/releases) and run:

```bash
python -m pip install /path/to/pycolmap-4.1.0+cu128.pipcuda.cudss-cp312-cp312-manylinux_2_34_x86_64.whl
```

```powershell
python -m pip install C:\path\to\pycolmap-4.1.0+cu128.pipcuda.cudss-cp312-cp312-win_amd64.whl
```

A complete uv consumer example is in
[`examples/uv/pyproject.toml`](examples/uv/pyproject.toml).

## Build and publish a release

The public entry point is
[`build-required-pycolmap.yml`](.github/workflows/build-required-pycolmap.yml).
It calls the fixed Linux and Windows builders in parallel, publishes nothing
unless both wheels pass, updates `release_wheels.json` on `master`, creates the
requested tag at that exact commit, and marks the GitHub release as latest.

```bash
gh workflow run build-required-pycolmap.yml \
  --ref master \
  -f release_tag=pycolmap-4.1.0-cu128-cudss-r3
```

The two platform workflows are reusable implementation details and cannot be
dispatched independently.

## Release gates

Each release verifies that:

- CUDA and cuDSS are enabled in the native build.
- Caspar is exported by COLMAP and exposed in the pycolmap API.
- `DOWNLOAD_ENABLED=ON` is retained for automatic ALIKED model downloads.
- wheel names, tags, metadata, and pinned NVIDIA dependencies are exact.
- NVIDIA runtime libraries are not duplicated inside the wheel.
- Linux repair includes the ONNX Runtime CUDA providers and resolves their full
  dependency graph against the installed NVIDIA packages.
- Windows repair produces a clean-installable wheel whose NVIDIA DLLs preload
  successfully before `_core.pyd` is imported.
- a clean environment can import pycolmap and download/open the default
  `aliked-n16rot.onnx` model.

## Repository layout

| Path | Responsibility |
| --- | --- |
| `CMakeLists.txt` | Builds pinned Ceres and COLMAP-for-pycolmap with CUDA, cuDSS, Caspar, and ONNX support |
| `.github/scripts/build_manylinux_wheel.sh` | Builds, repairs, and validates the single Linux wheel in a PyPA container |
| `.github/workflows/build-windows-pycolmap.yml` | Builds, repairs, and validates the single Windows wheel |
| `.github/workflows/build-required-pycolmap.yml` | Coordinates and publishes the two-wheel release |
| `patches/` | Minimal changes required on top of pinned upstream pycolmap/COLMAP |
| `release_wheels.json` and `wheel_redirect.py` | Pin and serve the released platform wheels |

Run the lightweight repository checks with:

```bash
bash -n .github/scripts/build_manylinux_wheel.sh
python3 -m py_compile .github/scripts/*.py scripts/*.py wheel_redirect.py
python3 -m json.tool vcpkg.json >/dev/null
python3 -m unittest discover tests
git diff --check
```
