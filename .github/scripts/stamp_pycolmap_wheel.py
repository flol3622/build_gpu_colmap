#!/usr/bin/env python3
"""Stamp the custom version and NVIDIA runtime requirements into pycolmap."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


# CUDA 12.8 Update 1 component versions from NVIDIA's redistrib_12.8.1.json.
# cuDNN is pinned to the version expected by ONNX Runtime 1.24.4, and cuDSS
# matches the version used to compile Ceres in the maintained wheel builds.
NVIDIA_RUNTIME_REQUIREMENTS = (
    "nvidia-cuda-runtime-cu12==12.8.90",
    "nvidia-cublas-cu12==12.8.4.1",
    "nvidia-cufft-cu12==11.3.3.83",
    "nvidia-curand-cu12==10.3.9.90",
    "nvidia-cusolver-cu12==11.7.3.90",
    "nvidia-cusparse-cu12==12.5.8.93",
    "nvidia-nvjitlink-cu12==12.8.93",
    "nvidia-cuda-nvrtc-cu12==12.8.93",
    "nvidia-nvtx-cu12==12.8.90",
    "nvidia-cudnn-cu12==9.10.2.21",
)
CUDSS_REQUIREMENT = "nvidia-cudss-cu12==0.7.1.4"


def stamp_pyproject(
    path: Path, version: str, external_nvidia_runtime: bool, with_cudss: bool
) -> None:
    text = path.read_text(encoding="utf-8")
    project_start = text.find("[project]")
    project_end = text.find("\n[", project_start + len("[project]"))
    if project_start < 0 or project_end < 0:
        raise RuntimeError(f"Could not locate the [project] section in {path}")

    before = text[:project_start]
    project = text[project_start:project_end]
    after = text[project_end:]

    project, version_count = re.subn(
        r'^version = "[^"]+"',
        f'version = "{version}"',
        project,
        count=1,
        flags=re.MULTILINE,
    )
    if version_count != 1:
        raise RuntimeError(f"Could not stamp the pycolmap version in {path}")

    if external_nvidia_runtime:
        requirements = ["numpy", *NVIDIA_RUNTIME_REQUIREMENTS]
        if with_cudss:
            requirements.append(CUDSS_REQUIREMENT)
        rendered = "dependencies = [\n" + "".join(
            f'  "{requirement}",\n' for requirement in requirements
        ) + "]"
        project, dependency_count = re.subn(
            r"^dependencies\s*=\s*\[[^\]]*\]",
            rendered,
            project,
            count=1,
            flags=re.MULTILINE | re.DOTALL,
        )
        if dependency_count != 1:
            raise RuntimeError(f"Could not stamp pycolmap dependencies in {path}")

    path.write_text(before + project + after, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pyproject", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--external-nvidia-runtime", action="store_true")
    parser.add_argument("--with-cudss", action="store_true")
    args = parser.parse_args()
    stamp_pyproject(
        args.pyproject,
        args.version,
        args.external_nvidia_runtime,
        args.with_cudss,
    )


if __name__ == "__main__":
    main()
