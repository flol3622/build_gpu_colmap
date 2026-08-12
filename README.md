<h1 align="center">GPU pycolmap wheels</h1>

<p align="center">
  <b><code>pip install</code> COLMAP with every GPU feature turned on — and skip the four-hour build.</b>
</p>

<p align="center">
  <a href="https://github.com/flol3622/build_gpu_colmap/releases"><img alt="Release" src="https://img.shields.io/github/v/release/flol3622/build_gpu_colmap?label=wheels"></a>
  <img alt="Python" src="https://img.shields.io/badge/python-3.12-blue">
  <img alt="CUDA" src="https://img.shields.io/badge/CUDA-12.8.1-76b900">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-Linux%20%7C%20Windows-lightgrey">
</p>

Two prebuilt [pycolmap](https://github.com/colmap/colmap) wheels — one Linux,
one Windows — each built with **everything enabled**. No compiler, no CUDA
toolkit, no `cmake` afternoon on your machine.

| | |
| --- | --- |
| **What** | Two maxed-out wheels: Linux x86_64 (glibc 2.34+) and Windows x86_64 |
| **Inside** | COLMAP 4.1.1 · CUDA 12.8.1 · cuDNN 9.10.2 · cuDSS 0.7.1 · ONNX Runtime GPU · ALIKED/LightGlue · Caspar bundle adjustment |
| **You need** | An NVIDIA driver. That's it — the CUDA runtime arrives as pinned pip dependencies |
| **For** | Researchers and engineers who want GPU SfM/MVS from Python and don't want to spend a day on `cmake` |

Building pycolmap with CUDA, cuDSS and ONNX support from source is slow,
fragile, and different on every machine — and most prebuilt wheels quietly leave
half the accelerated features out. This repo does the hard build once, in CI,
with nothing switched off, and hands you the result.

It grew out of [lyehe/build_gpu_colmap](https://github.com/lyehe/build_gpu_colmap).
Rather than exposing a build matrix, it commits to exactly two fully-loaded
configurations and keeps them working. Not a general COLMAP distribution: no CPU
wheels, no GUI packages, no options to pick from.

## Install

```bash
uv add "git+https://github.com/flol3622/build_gpu_colmap"
uv run python -c "import pycolmap; print(pycolmap.__version__)"
```

That installs a tiny redirect package which picks the wheel for your platform
from the latest pinned release and checks its size and SHA-256. Nothing is
compiled locally. See [`examples/uv/pyproject.toml`](examples/uv/pyproject.toml)
for a full consumer project.

Prefer doing it by hand? Grab the asset from
[Releases](https://github.com/flol3622/build_gpu_colmap/releases) and
`pip install` the `.whl` directly.

## Working on this repo

Build system, release workflow, and the checks every wheel has to pass live in
[AGENTS.md](AGENTS.md).
