# GPU pycolmap wheel builder

GPU-enabled `pycolmap` wheels, built, repaired, validated, and published for
you. This is a single-purpose fork of
[`lyehe/build_gpu_colmap`](https://github.com/lyehe/build_gpu_colmap) that
targets modern Linux, Red Hat-compatible Linux, and Windows.

It's not a general COLMAP distribution — no CPU-wheel matrix, no standalone
COLMAP archives, no GUI packages, no every-upstream-variant coverage. Just one
job, done well: reproducible GPU pycolmap wheels with CUDA and cuDSS already
bundled in. The only thing you still need on the host is an NVIDIA display
driver.

## Current wheel set

The current release is
[`pycolmap-4.1.0-cu128-cudss`](https://github.com/flol3622/build_gpu_colmap/releases/tag/pycolmap-4.1.0-cu128-cudss):

| Platform | Wheel | Baseline |
| --- | --- | --- |
| Linux x86_64 | `pycolmap-4.1.0+cu128.bundled.cudss-cp312-cp312-manylinux_2_34_x86_64.whl` | glibc 2.34; AlmaLinux/RHEL 9 class and newer |
| Linux x86_64 | `pycolmap-4.1.0+cu128.bundled.cudss-cp312-cp312-manylinux_2_35_x86_64.whl` | glibc 2.35-tagged companion for newer distributions |
| Windows AMD64 | `pycolmap-4.1.0+cuda.cudss-cp312-cp312-win_amd64.whl` | Windows 10/11 or Server 2022 |

These wheels target CPython 3.12 and bundle CUDA 12.8 runtime dependencies,
cuDSS 0.7.1.4, and the Caspar bundle-adjustment backend. If you're not sure
which Linux wheel to grab, pick `manylinux_2_34`: it satisfies glibc 2.34 and
runs fine on glibc 2.35 and newer too. The second file is only there for
consumers who specifically need the exact `manylinux_2_35` tag.

Need AlmaLinux/RHEL 8 support instead? Build a `manylinux_2_28_x86_64` wheel
yourself with the custom Linux workflow described below.

## Install with uv

Add this repository directly to any uv project:

```bash
uv add "git+https://github.com/flol3622/build_gpu_colmap"
uv run python -c "import pycolmap; print(pycolmap.__version__)"
```

The repository's packaging backend selects the matching released wheel,
verifies its pinned SHA-256 digest, and gives it to uv. It does not compile
COLMAP locally. The current Git install supports CPython 3.12 on Linux x86_64
(glibc 2.34 or newer) and Windows x86_64. The wheel is about 1.2–1.3 GiB, so
the first resolution can take a while.

To make an environment reproducible, append the packaging commit SHA:

```bash
uv add "git+https://github.com/flol3622/build_gpu_colmap@${COMMIT_SHA}"
```

## Install a downloaded wheel

Download the matching wheel from
[GitHub Releases](https://github.com/flol3622/build_gpu_colmap/releases), then
install it directly:

```bash
python -m pip install /path/to/pycolmap-4.1.0+cu128.bundled.cudss-cp312-cp312-manylinux_2_34_x86_64.whl
```

```powershell
python -m pip install C:\path\to\pycolmap-4.1.0+cuda.cudss-cp312-cp312-win_amd64.whl
```

The wheel bundles user-space GPU libraries, not the kernel/display driver — you
still need an NVIDIA driver compatible with CUDA 12.8 on the host.

## Use the wheels in a uv project

Want a working example? See
[`examples/uv/pyproject.toml`](examples/uv/pyproject.toml). It's just an
ordinary `pycolmap` dependency plus uv-only, platform-specific direct wheel
sources:

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
ignore it. The template picks the `manylinux_2_34` wheel since it also runs on
glibc 2.35 and newer — swap in a custom 2.28 build if you're targeting
AlmaLinux/RHEL 8. See uv's docs on
[platform-specific and multiple dependency sources](https://docs.astral.sh/uv/concepts/projects/dependencies/#multiple-sources)
for more.

## What every wheel must prove

Nothing gets uploaded until it passes every applicable check:

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

The ALIKED gate lives in
[`validate_aliked_download.py`](.github/scripts/validate_aliked_download.py).
It makes sure runtime downloading actually works, not just that
`-DDOWNLOAD_ENABLED=ON` was accepted at build time.

## GitHub Actions for this fork

Three workflows, three jobs:

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

The Linux workflow always compiles inside the selected PyPA container — no
building on Ubuntu and relabeling the result afterward.

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

The Windows workflow sticks to one known-good combo: Windows Server 2022,
CPython 3.12, CUDA 12.8.1, cuDSS 0.7.1.4, and Caspar. Only touch its single
matrix entry when you're deliberately adding a new supported Windows variant.

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
gigabytes of dependencies, and wheel repair work — roughly an hour per
uncached platform.

Adding a new variant? Keep these in sync:

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
