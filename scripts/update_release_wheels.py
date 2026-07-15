#!/usr/bin/env python3
"""Generate the pinned release-wheel manifest consumed by wheel_redirect.py."""

from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def describe_wheel(path: Path) -> dict[str, object]:
    if path.stat().st_size >= 2 * 1024**3:
        raise RuntimeError(f"Release asset exceeds GitHub's 2 GiB limit: {path}")
    with zipfile.ZipFile(path) as archive:
        metadata_names = [
            name for name in archive.namelist() if name.endswith(".dist-info/METADATA")
        ]
        wheel_names = [
            name for name in archive.namelist() if name.endswith(".dist-info/WHEEL")
        ]
        if len(metadata_names) != 1 or len(wheel_names) != 1:
            raise RuntimeError(f"Unexpected dist-info layout in {path}")
        metadata = archive.read(metadata_names[0])
        wheel_metadata = archive.read(wheel_names[0])

    return {
        "filename": path.name,
        "sha256": sha256_file(path),
        "size": path.stat().st_size,
        "metadata_sha256": sha256_bytes(metadata),
        "wheel_metadata_sha256": sha256_bytes(wheel_metadata),
    }


def select_one(wheels: list[Path], suffix: str) -> Path:
    matches = [wheel for wheel in wheels if wheel.name.endswith(suffix)]
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected exactly one wheel ending in {suffix!r}, found: "
            + ", ".join(path.name for path in matches)
        )
    return matches[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--wheel-dir", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path("release_wheels.json"))
    args = parser.parse_args()

    wheels = sorted(args.wheel_dir.glob("*.whl"))
    linux = select_one(wheels, "manylinux_2_34_x86_64.whl")
    windows = select_one(wheels, "win_amd64.whl")
    manifest = {
        "release_tag": args.release_tag,
        "assets": {
            "linux": describe_wheel(linux),
            "windows": describe_wheel(windows),
        },
    }
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
