# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project Overview

**GPU pycolmap wheel builder** — a single-purpose fork of
[`lyehe/build_gpu_colmap`](https://github.com/lyehe/build_gpu_colmap), published as
`flol3622/build_gpu_colmap`. Its only job is to build, repair, validate, and publish
**GPU-enabled `pycolmap` wheels** with exact CUDA, cuDNN, and cuDSS Python runtime
dependencies, so consumers need nothing but an NVIDIA display driver and an ordinary
pip/uv install.

This is **not** a general COLMAP distribution: no CPU wheel matrix, no standalone
COLMAP archives, no GUI packages.

Current release line: `pycolmap-4.1.0-cu128-cudss-r3` — CPython 3.12, CUDA 12.8,
cuDSS 0.7.1.4,
Caspar bundle-adjustment backend, for `manylinux_2_34`/`manylinux_2_35` x86_64 and
`win_amd64`.

## How wheels are built

All real builds happen in **GitHub Actions** — they need CUDA installers, gigabytes of
dependencies, and wheel repair, roughly an hour per uncached platform. Do not attempt a
full wheel build locally.

Three workflows in `.github/workflows/`:

| Workflow | Purpose |
|---|---|
| `build-required-pycolmap.yml` | The maintained wheel subset (release builds) |
| `build-custom-pycolmap.yml` | On-demand Linux builds via `workflow_dispatch` |
| `build-pycolmap.yml` | Maintained Windows builds |

(`build-colmap.yml`, `release.yml`, `update-wheel-index.yml` are stale leftovers from
the old approach.)

### The Linux build script

`.github/scripts/build_custom_manylinux_wheel.sh` runs as root inside a
`quay.io/pypa/<manylinux_tag>` Docker container. It takes **no CLI arguments** — all
configuration is via environment variables:

| Variable | Default | Allowed |
|---|---|---|
| `PYTHON_VERSION` | `3.12` | 3.10 – 3.14 |
| `CUDA_VERSION` | `12.8` | 12.8, 13.0, 13.1 |
| `MANYLINUX_TAG` | `manylinux_2_34_x86_64` | also `manylinux_2_28_x86_64` (CUDA 12.8 only) |
| `BUNDLE_CUDA` | `false` | use pinned NVIDIA Python dependencies (`true` retains the legacy monolithic mode) |
| `WITH_CUDSS` | `true` | include cuDSS sparse solver |
| `CUDSS_VERSION` | `0.7.1.4` | |

The external-runtime mode is currently restricted to CUDA 12.8. CUDA 13 custom
builds must set `BUNDLE_CUDA=true` until matching cu13 dependency pins and the
ONNX Runtime CUDA 12 compatibility set are modeled together.

Flow:

1. Validates the Python/CUDA/manylinux combination and the container glibc.
2. Installs the CUDA toolkit from NVIDIA's rhel8/rhel9 dnf repo, plus build toolchain.
3. Downloads cuDSS to `/opt/nvidia/cudss` and discovers `cudss_DIR`.
4. Applies `patches/pycolmap-caspar-bindings.patch` to `third_party/colmap-for-pycolmap`
   (idempotent).
5. **Stage 1 — top-level CMake build** (`CMakeLists.txt`, Ninja, vcpkg toolchain):
   builds Ceres and COLMAP-for-pycolmap via `ExternalProject` with
   `-DBUILD_COLMAP=OFF -DBUILD_COLMAP_FOR_PYCOLMAP=ON -DBUILD_CERES=ON
   -DCUDA_ENABLED=ON -DCASPAR_ENABLED=ON -DDOWNLOAD_ENABLED=ON
   -DGFLAGS_USE_TARGET_NAMESPACE=ON`, then validates the installed CMake packages
   (Caspar targets present, `DOWNLOAD_ENABLED ON`, Ceres exports the cuDSS component).
6. **Stage 2 — wheel build**: stamps the computed wheel version and, for lightweight
   builds, exact NVIDIA runtime requirements into the pycolmap `pyproject.toml`
   (*after* stage 1 — the ExternalProject build restores the upstream version), then
   `pip wheel` in `third_party/colmap-for-pycolmap` against the already-built
   COLMAP/Ceres.
7. Repairs with `auditwheel` (always excluding `libcuda.so.1`; excluding all CUDA
   runtime libs when `BUNDLE_CUDA=false`), manually injects the dlopen'd
   `libonnxruntime_providers_shared.so` / `_cuda.so` with `$ORIGIN` rpaths.
8. Runs post-checks (see validation gates), emits a `manylinux_2_35` companion tag for
   `manylinux_2_34` wheels, and writes wheel + `*.build_info.json` to
   `custom-wheelhouse/`.

Wheel version suffix logic: external runtime + cuDSS →
`+cu<compact>.pipcuda.cudss` (the maintained configuration); external runtime only →
`+cu<compact>.pipcuda`; legacy bundled + cuDSS → `+cu<compact>.bundled.cudss`;
legacy bundle only → `+cu<compact>.bundled`.

### Validation gates — never weaken these

Every wheel must prove: CUDA enabled; Ceres exports the cuDSS component; Caspar present
in COLMAP targets and the pycolmap API; `DOWNLOAD_ENABLED=ON`; filename/tags/metadata
consistent; auditwheel/delvewheel repair applied; exact NVIDIA dependencies present
and not duplicated in lightweight wheels; installs and imports in a clean environment; ALIKED
`aliked-n16rot.onnx` download works from an empty cache
(`.github/scripts/validate_aliked_download.py`).

## PEP 517 redirect backend

The root `pyproject.toml` declares `wheel_redirect.py` as the build backend. It does
not compile anything: `uv add "git+https://github.com/flol3622/build_gpu_colmap"`
resolves through it, and it **downloads the matching pre-built wheel** from the pinned
GitHub release, verifying size and SHA-256. It reads dist-info metadata via HTTP range
requests so metadata resolution doesn't download the ~1.3 GiB wheel.

- Supports CPython 3.12 on x86_64 Linux (glibc ≥ 2.34) and Windows only.
- `release_wheels.json` pins filenames, sizes, and hashes. The maintained release
  workflow regenerates and commits it before publishing a release.
- Tests: `tests/test_wheel_redirect.py` (unittest-style) —
  `python3 -m unittest discover tests`.

## Key files

| Path | Role |
|---|---|
| `CMakeLists.txt` | ExternalProject orchestration of Ceres + COLMAP-for-pycolmap |
| `vcpkg.json` | Native dependency manifest (vcpkg manifest mode) |
| `overlay-ports/` | vcpkg port patches (ceres, suitesparse-cholmod, suitesparse-spqr) |
| `patches/` | Source patches applied by the build script (Caspar bindings) |
| `cmake/` | `patch_*.cmake` helpers used by `CMakeLists.txt` |
| `.github/scripts/build_custom_manylinux_wheel.sh` | The Linux wheel build (moved here from `scripts_linux/`) |
| `.github/scripts/stamp_pycolmap_wheel.py` | Stamps the local version and exact NVIDIA requirements |
| `.github/scripts/validate_aliked_download.py` | ALIKED download gate |
| `scripts/emit_build_info.py` | Writes `*.build_info.json` next to each wheel |
| `scripts/update_release_wheels.py` | Generates the pinned manifest from released wheels |
| `wheel_redirect.py` + `release_wheels.json` + `pyproject.toml` | PEP 517 backend and pinned released-wheel manifest |
| `examples/uv/pyproject.toml` | Consumer example with platform-specific wheel URLs |
| `third_party/` | Submodules: vcpkg, ceres-solver, colmap, colmap-for-pycolmap |

## Local checks before pushing

```bash
bash -n .github/scripts/build_custom_manylinux_wheel.sh
python3 -m py_compile .github/scripts/validate_aliked_download.py
python3 -m py_compile .github/scripts/stamp_pycolmap_wheel.py scripts/update_release_wheels.py
python3 -m json.tool vcpkg.json >/dev/null
actionlint \
  .github/workflows/build-required-pycolmap.yml \
  .github/workflows/build-custom-pycolmap.yml \
  .github/workflows/build-pycolmap.yml
python3 -m unittest discover tests
git diff --check
```

## Conventions

- Configure builds through environment variables and workflow inputs, not new CLI flags.
- Patch native dependencies via `overlay-ports/`; patch pycolmap sources via `patches/`
  (keep patches idempotent — the script re-runs on cached checkouts).
- `-DGFLAGS_USE_TARGET_NAMESPACE=ON` is required everywhere COLMAP is configured
  (vcpkg's gflags exports `gflags::gflags`; without it, linking fails with
  `cannot open input file 'gflags.lib'`).
- CUDA architectures: `75;80;86;89;90` (plus `120` for CUDA 13+).
- vcpkg binary cache lives at `.cache/vcpkg` and is keyed on
  `vcpkg.json` + `overlay-ports/**` + `patches/**` — touching those invalidates CI
  caches, so expect the next run to be slow.

## Legacy areas — do not extend

`scripts_windows/`, `scripts_linux/`, `docs/`, and `releases/` belong to the old
"local self-contained build environment" approach that predates the CI wheel pipeline.
They still exist but are not referenced by the current workflows. Don't add features
there; if a change seems to require them, it probably belongs in
`.github/scripts/` or the workflows instead.
