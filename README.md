# GPU pycolmap wheel builder

This is a single-purpose fork of
[`lyehe/build_gpu_colmap`](https://github.com/lyehe/build_gpu_colmap): it builds,
repairs, validates, and publishes self-contained GPU-enabled **pycolmap wheels**
for modern Linux, Red Hat-compatible Linux, and Windows.

The fork is intentionally not a general COLMAP distribution. It does not try to
maintain a CPU-wheel matrix, standalone COLMAP archives, GUI packages, or every
upstream build variant. Its job is to make missing/custom pycolmap GPU wheels
reproducibly, with the linked CUDA user-space libraries and cuDSS included.
Only the NVIDIA display driver remains a system dependency.

## Current wheel set

The current release is
[`pycolmap-4.1.0-cu128-cudss`](https://github.com/flol3622/build_gpu_colmap/releases/tag/pycolmap-4.1.0-cu128-cudss):

| Platform | Wheel | Baseline |
| --- | --- | --- |
| Linux x86_64 | `pycolmap-4.1.0+cu128.bundled.cudss-cp312-cp312-manylinux_2_34_x86_64.whl` | glibc 2.34; AlmaLinux/RHEL 9 class and newer |
| Linux x86_64 | `pycolmap-4.1.0+cu128.bundled.cudss-cp312-cp312-manylinux_2_35_x86_64.whl` | glibc 2.35-tagged companion for newer distributions |
| Windows AMD64 | `pycolmap-4.1.0+cuda.cudss-cp312-cp312-win_amd64.whl` | Windows 10/11 or Server 2022 |

These wheels target CPython 3.12 and include CUDA 12.8 runtime dependencies,
cuDSS 0.7.1.4, and the Caspar bundle-adjustment backend. The manylinux_2_34
wheel is the broadest Linux choice: a binary that satisfies glibc 2.34 also
runs on glibc 2.35 and newer. The second file exists for consumers that require
an exact manylinux_2_35 tag; its internal `WHEEL` tag and `RECORD` are rewritten
consistently.

For AlmaLinux/RHEL 8-class systems, build a `manylinux_2_28_x86_64` wheel with
the custom Linux workflow described below.

## Install a released wheel

Download the matching wheel from
[GitHub Releases](https://github.com/flol3622/build_gpu_colmap/releases), then
install it directly:

```bash
python -m pip install /path/to/pycolmap-4.1.0+cu128.bundled.cudss-cp312-cp312-manylinux_2_34_x86_64.whl
```

```powershell
python -m pip install C:\path\to\pycolmap-4.1.0+cuda.cudss-cp312-cp312-win_amd64.whl
```

The wheel bundles user-space GPU libraries, not the kernel/display driver. The
host still needs an NVIDIA driver compatible with CUDA 12.8.

## Use the wheels in a uv project

A complete consumer template is available at
[`examples/uv/pyproject.toml`](examples/uv/pyproject.toml). The important part
is an ordinary `pycolmap` dependency plus uv-only, platform-specific direct
wheel sources:

```toml
[project]
name = "my-reconstruction-project"
version = "0.1.0"
requires-python = ">=3.12,<3.13"
dependencies = [
  "pycolmap>=4.1.0,<4.2; (sys_platform == 'linux' and platform_machine == 'x86_64') or (sys_platform == 'win32' and platform_machine == 'AMD64')",
]

[tool.uv]
package = false
required-environments = [
  "sys_platform == 'linux' and platform_machine == 'x86_64'",
  "sys_platform == 'win32' and platform_machine == 'AMD64'",
]

[tool.uv.sources]
pycolmap = [
  { url = "https://github.com/flol3622/build_gpu_colmap/releases/download/pycolmap-4.1.0-cu128-cudss/pycolmap-4.1.0%2Bcu128.bundled.cudss-cp312-cp312-manylinux_2_34_x86_64.whl", marker = "sys_platform == 'linux' and platform_machine == 'x86_64'" },
  { url = "https://github.com/flol3622/build_gpu_colmap/releases/download/pycolmap-4.1.0-cu128-cudss/pycolmap-4.1.0%2Bcuda.cudss-cp312-cp312-win_amd64.whl", marker = "sys_platform == 'win32' and platform_machine == 'AMD64'" },
]
```

Then resolve and install the project:

```bash
uv lock
uv sync
uv run python -c "import pycolmap; print(pycolmap.__version__)"
```

`tool.uv.sources` is project-local uv configuration; other package managers
ignore it. The template intentionally selects the `manylinux_2_34` wheel because
it also runs on glibc 2.35 and newer. Point the Linux URL at a custom 2.28 build
when targeting AlmaLinux/RHEL 8. See uv's documentation for
[platform-specific and multiple dependency sources](https://docs.astral.sh/uv/concepts/projects/dependencies/#multiple-sources).

## What every wheel must prove

A build is uploaded only after all applicable checks pass:

- CUDA is enabled in the native COLMAP build.
- Ceres detects and exports its cuDSS component.
- Caspar is present in the installed COLMAP targets and pycolmap API.
- `DOWNLOAD_ENABLED=ON` is present in the installed COLMAP CMake package.
- The final filename, Python/ABI tags, platform tag, and package metadata match.
- Linux wheels pass `auditwheel`; Windows wheels are repaired with `delvewheel`.
- The linked CUDA runtime and cuDSS shared libraries are physically in the wheel.
- The repaired wheel installs and imports in a clean environment.
- From an empty home/cache and without assigning a model path, constructing an
  `ALIKED_N16ROT` extractor downloads, verifies, caches, and opens the default
  `aliked-n16rot.onnx` model.

The ALIKED gate is implemented in
[`validate_aliked_download.py`](.github/scripts/validate_aliked_download.py).
It prevents a wheel from passing merely because the build accepted
`-DDOWNLOAD_ENABLED=ON`; runtime downloading must actually work.

## GitHub Actions for this fork

There are three pycolmap entry points:

| Workflow | Purpose | Output |
| --- | --- | --- |
| [`build-required-pycolmap.yml`](.github/workflows/build-required-pycolmap.yml) | Build the maintained release subset in parallel | Two Linux CPython 3.12 wheels plus one Windows CPython 3.12 wheel |
| [`build-custom-pycolmap.yml`](.github/workflows/build-custom-pycolmap.yml) | Build an on-demand Linux combination in a real PyPA manylinux container | Validated wheel(s) and `build_info.json` |
| [`build-pycolmap.yml`](.github/workflows/build-pycolmap.yml) | Build the maintained Windows configuration | CUDA 12.8.1 + cuDSS CPython 3.12 wheel |

### Build the maintained subset

From the Actions UI, run **Build Required pycolmap Wheel Subset**. With the
GitHub CLI:

```bash
gh workflow run build-required-pycolmap.yml
gh run list --workflow build-required-pycolmap.yml --limit 1
gh run watch <run-id> --exit-status
```

With an empty `release_tag`, successful jobs upload 14-day workflow artifacts.
To upload directly to a release, create the release first and pass its existing
tag:

```bash
TAG=pycolmap-4.1.0-cu128-cudss
gh release create "$TAG" --draft --title "pycolmap 4.1.0 CUDA 12.8 + cuDSS wheels"
gh workflow run build-required-pycolmap.yml -f release_tag="$TAG"
```

Keep the release in draft state until all expected filenames and checksums are
verified, then publish it:

```bash
gh release view "$TAG" --json assets --jq '.assets[] | [.name, .size] | @tsv'
gh release edit "$TAG" --draft=false
```

### Build a custom Linux wheel

The Linux workflow always compiles inside the selected PyPA container; it does
not build on Ubuntu and relabel the result afterward.

```bash
gh workflow run build-custom-pycolmap.yml \
  -f python_version=3.12 \
  -f cuda_version=12.8 \
  -f manylinux_tag=manylinux_2_34_x86_64 \
  -f cudss=true \
  -f bundle_cuda=true
```

Inputs:

| Input | Accepted values | Notes |
| --- | --- | --- |
| `python_version` | `3.10`, `3.11`, `3.12`, `3.13`, `3.14` | Must exist in the selected PyPA image |
| `cuda_version` | `12.8`, `13.0`, `13.1` | CUDA 13 adds Blackwell/SM 120 support |
| `manylinux_tag` | `manylinux_2_34_x86_64`, `manylinux_2_28_x86_64` | 2.34 is AlmaLinux/RHEL 9 class; 2.28 is AlmaLinux/RHEL 8 class |
| `cudss` | `true`, `false` | Enables the Ceres cuDSS sparse backend |
| `bundle_cuda` | `true`, `false` | Includes or excludes linked CUDA/cuDSS runtime libraries |
| `release_tag` | existing tag or empty | Empty creates an Actions artifact; a tag uploads directly to its release |

The manylinux_2_28 path is currently limited to CUDA 12.8. The
manylinux_2_34 path emits both 2.34 and 2.35 filenames after validating the
actual binary against the 2.34 policy.

### Build the maintained Windows wheel

Run **Build Required Windows pycolmap Wheel** or:

```bash
gh workflow run build-pycolmap.yml
```

The Windows workflow is deliberately fixed to Windows Server 2022, CPython
3.12, CUDA 12.8.1, cuDSS 0.7.1.4, and Caspar. Change its single matrix entry
only when adding a deliberately supported Windows variant.

### Retry a failed build

Native CUDA builds are long. Retry only failed jobs rather than restarting
successful platforms:

```bash
gh run rerun <run-id> --failed
gh run watch <run-id> --exit-status
```

## Developer guide

Clone with submodules and keep them pinned:

```bash
git clone --recurse-submodules https://github.com/flol3622/build_gpu_colmap.git
cd build_gpu_colmap
git submodule update --init --recursive
```

Important files:

| Path | Responsibility |
| --- | --- |
| [`CMakeLists.txt`](CMakeLists.txt) | Orchestrates pinned Ceres and COLMAP builds and forwards CUDA, cuDSS, Caspar, and download settings |
| [`build_custom_manylinux_wheel.sh`](.github/scripts/build_custom_manylinux_wheel.sh) | Installs CUDA/cuDSS in the selected manylinux image, builds, repairs, stamps, and validates Linux wheels |
| [`build-custom-pycolmap.yml`](.github/workflows/build-custom-pycolmap.yml) | Linux workflow inputs, container selection, cache, artifacts, and release upload |
| [`build-pycolmap.yml`](.github/workflows/build-pycolmap.yml) | Windows build, delvewheel repair, runtime tests, and exact filename validation |
| [`build-required-pycolmap.yml`](.github/workflows/build-required-pycolmap.yml) | Maintained cross-platform subset |
| [`validate_aliked_download.py`](.github/scripts/validate_aliked_download.py) | Fresh-cache ALIKED runtime download test |
| [`vcpkg.json`](vcpkg.json) | Native dependency manifest, including download-support dependencies |
| [`patches/`](patches) | Minimal patches applied to the pinned upstream pycolmap/COLMAP source |

Run lightweight checks before pushing:

```bash
bash -n .github/scripts/build_custom_manylinux_wheel.sh
python3 -m py_compile .github/scripts/validate_aliked_download.py
python3 -m json.tool vcpkg.json >/dev/null
actionlint \
  .github/workflows/build-required-pycolmap.yml \
  .github/workflows/build-custom-pycolmap.yml \
  .github/workflows/build-pycolmap.yml
git diff --check
```

The full build belongs in GitHub Actions: it needs CUDA installers, several
gigabytes of dependencies and wheel repair work, and approximately an hour per
uncached platform.

When adding a variant, update all of the following together:

1. Workflow choices or the Windows matrix.
2. Version suffix and exact expected filename.
3. CUDA/cuDSS install and library search paths.
4. Wheel repair exclusions or bundled-library assertions.
5. Release documentation and uv source markers/URLs.
6. ALIKED, import, metadata, and platform-tag validation gates.

Do not weaken a validation to make a filename appear. Fix the build so the
wheel genuinely satisfies the name it publishes.

## License and upstream projects

The build orchestration in this repository is released under
[The Unlicense](LICENSE). COLMAP, Ceres, CUDA, cuDSS, and all other bundled
dependencies retain their own licenses.

- Upstream build repository: [`lyehe/build_gpu_colmap`](https://github.com/lyehe/build_gpu_colmap)
- COLMAP: [`colmap/colmap`](https://github.com/colmap/colmap)
- pycolmap documentation: [COLMAP Python bindings](https://colmap.github.io/pycolmap/pycolmap.html)
- manylinux images and policy: [`pypa/manylinux`](https://github.com/pypa/manylinux)
