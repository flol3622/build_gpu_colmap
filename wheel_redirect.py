"""PEP 517 backend that installs the matching pre-built pycolmap wheel.

Building pycolmap from this Git repository would require a full CUDA toolchain.
For package-manager installs, this backend instead returns the tested wheel from
the corresponding GitHub release.  Release assets are pinned by SHA-256 so a
changed or corrupted download is never installed.
"""

from __future__ import annotations

import hashlib
import platform
import struct
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping


_RELEASE_BASE = (
    "https://github.com/flol3622/build_gpu_colmap/releases/download/"
    "pycolmap-4.1.0-cu128-cudss-r2"
)
_DOWNLOAD_CHUNK_SIZE = 8 * 1024 * 1024
_PROGRESS_INTERVAL = 128 * 1024 * 1024


@dataclass(frozen=True)
class WheelAsset:
    filename: str
    sha256: str
    size: int
    metadata_sha256: str
    wheel_metadata_sha256: str

    @property
    def url(self) -> str:
        # GitHub's release URLs encode the local-version separator.
        return f"{_RELEASE_BASE}/{self.filename.replace('+', '%2B')}"


_ASSETS: Mapping[str, WheelAsset] = {
    "linux": WheelAsset(
        filename=(
            "pycolmap-4.1.0+cu128.bundled.cudss-cp312-cp312-manylinux_2_34_x86_64.whl"
        ),
        sha256="07a8455d8341f76fdfdd42b8d9f823540ac8c35ff106759df4cc71abd384d3e0",
        size=1_741_093_810,
        metadata_sha256="98923fbea56806c1bc5b37e72d311db3a0fab637bc19bea9b42d45709d83fc91",
        wheel_metadata_sha256=(
            "7d1aaac129bf355bf7cfb7b0539edb6abd3622543e66153b1f3492ba114d62f4"
        ),
    ),
    "windows": WheelAsset(
        filename="pycolmap-4.1.0+cuda.cudss-cp312-cp312-win_amd64.whl",
        sha256="06bc05bcad385b404a342a0b69c7eb45f06c1bf69decccc3e7879fa4f8e3b422",
        size=1_211_659_668,
        metadata_sha256="e5bc62d4c5fcd8cf7ec46d84bb51e050ae972ad40aa917ac349aa1381f0208f0",
        wheel_metadata_sha256=(
            "f15bc60f9bb7ebe0d4e917d2e3627494a9115477e597efbaa12905cd60a9153b"
        ),
    ),
}


def _select_asset(
    *,
    system: str | None = None,
    machine: str | None = None,
    python_version: tuple[int, int] | None = None,
    libc: tuple[str, str] | None = None,
) -> WheelAsset:
    system = (system or platform.system()).lower()
    machine = (machine or platform.machine()).lower()
    python_version = python_version or sys.version_info[:2]

    if platform.python_implementation() != "CPython":
        raise RuntimeError("GPU pycolmap wheels require CPython.")
    if python_version != (3, 12):
        raise RuntimeError(
            "GPU pycolmap wheels currently require CPython 3.12; "
            f"the build environment is Python {python_version[0]}.{python_version[1]}."
        )
    if machine not in {"amd64", "x86_64"}:
        raise RuntimeError(
            "GPU pycolmap wheels require an x86-64 machine; "
            f"detected {machine or 'an unknown architecture'}."
        )

    if system == "linux":
        libc_name, libc_version = libc or platform.libc_ver()
        if libc_name.lower() == "glibc" and libc_version:
            try:
                glibc = tuple(int(part) for part in libc_version.split(".")[:2])
            except ValueError:
                glibc = ()
            if glibc and glibc < (2, 34):
                raise RuntimeError(
                    "The released GPU pycolmap wheel requires glibc 2.34 or newer; "
                    f"detected glibc {libc_version}."
                )
        return _ASSETS["linux"]
    if system == "windows":
        return _ASSETS["windows"]

    raise RuntimeError(
        "GPU pycolmap wheels are available only for Linux x86-64 and "
        f"Windows x86-64; detected {system or 'an unknown OS'} {machine}."
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(_DOWNLOAD_CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _download(asset: WheelAsset, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        asset.url,
        headers={
            "Accept": "application/octet-stream",
            "User-Agent": "build-gpu-colmap-pep517/1",
        },
    )

    print(
        f"Downloading {asset.filename} ({asset.size / 1024**3:.2f} GiB)...",
        file=sys.stderr,
    )
    digest = hashlib.sha256()
    downloaded = 0
    next_progress = _PROGRESS_INTERVAL
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{asset.filename}.",
            suffix=".part",
            dir=destination.parent,
            delete=False,
        ) as output:
            temporary = Path(output.name)
            with urllib.request.urlopen(request, timeout=60) as response:
                while chunk := response.read(_DOWNLOAD_CHUNK_SIZE):
                    output.write(chunk)
                    digest.update(chunk)
                    downloaded += len(chunk)
                    if downloaded >= next_progress:
                        print(
                            f"  downloaded {downloaded / 1024**3:.2f} / "
                            f"{asset.size / 1024**3:.2f} GiB",
                            file=sys.stderr,
                        )
                        next_progress += _PROGRESS_INTERVAL
        if downloaded != asset.size:
            raise RuntimeError(
                f"Downloaded size mismatch for {asset.filename}: "
                f"expected {asset.size} bytes, received {downloaded}."
            )
        actual_digest = digest.hexdigest()
        if actual_digest != asset.sha256:
            raise RuntimeError(
                f"SHA-256 mismatch for {asset.filename}: expected {asset.sha256}, "
                f"received {actual_digest}."
            )
        temporary.replace(destination)
    except (OSError, urllib.error.URLError) as error:
        raise RuntimeError(f"Could not download {asset.url}: {error}") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _ensure_wheel(asset: WheelAsset, directory: Path) -> Path:
    wheel = directory / asset.filename
    if wheel.exists():
        if wheel.stat().st_size == asset.size and _sha256(wheel) == asset.sha256:
            return wheel
        wheel.unlink()
    _download(asset, wheel)
    return wheel


def _fetch_range(asset: WheelAsset, start: int, end: int) -> bytes:
    request = urllib.request.Request(
        asset.url,
        headers={
            "Range": f"bytes={start}-{end}",
            "User-Agent": "build-gpu-colmap-pep517/1",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            status = response.getcode()
            payload = response.read()
    except (OSError, urllib.error.URLError) as error:
        raise RuntimeError(
            f"Could not read wheel metadata from {asset.url}: {error}"
        ) from error
    expected_size = end - start + 1
    if status != 206 or len(payload) != expected_size:
        raise RuntimeError(
            f"The release server did not honor a metadata range request for "
            f"{asset.filename} (HTTP {status}, expected {expected_size} bytes, "
            f"received {len(payload)})."
        )
    return payload


def _remote_dist_info(asset: WheelAsset) -> tuple[str, Mapping[str, bytes]]:
    """Read exact dist-info metadata using small HTTP ZIP range requests."""
    tail_size = min(asset.size, 128 * 1024)
    tail_offset = asset.size - tail_size
    tail = _fetch_range(asset, tail_offset, asset.size - 1)
    end_record = tail.rfind(b"PK\x05\x06")
    if end_record < 0 or len(tail) - end_record < 22:
        raise RuntimeError(f"Could not find the ZIP end record in {asset.filename}.")
    _, _, _, _, _, central_size, central_offset, _ = struct.unpack_from(
        "<4s4H2LH", tail, end_record
    )
    central = _fetch_range(asset, central_offset, central_offset + central_size - 1)

    entries: dict[str, tuple[int, int, int]] = {}
    position = 0
    while (
        position + 46 <= len(central)
        and central[position : position + 4] == b"PK\x01\x02"
    ):
        compression = struct.unpack_from("<H", central, position + 10)[0]
        compressed_size = struct.unpack_from("<L", central, position + 20)[0]
        name_size, extra_size, comment_size = struct.unpack_from(
            "<3H", central, position + 28
        )
        local_offset = struct.unpack_from("<L", central, position + 42)[0]
        name_start = position + 46
        name = central[name_start : name_start + name_size].decode("utf-8")
        if name.endswith(".dist-info/METADATA") or name.endswith(".dist-info/WHEEL"):
            entries[name] = (compression, compressed_size, local_offset)
        position += 46 + name_size + extra_size + comment_size

    if len(entries) != 2:
        raise RuntimeError(
            f"Expected METADATA and WHEEL entries in {asset.filename}, found "
            f"{sorted(entries)}."
        )
    dist_info_directories = {Path(name).parts[0] for name in entries}
    if len(dist_info_directories) != 1:
        raise RuntimeError(f"Inconsistent dist-info paths in {asset.filename}.")

    contents: dict[str, bytes] = {}
    for archive_name, (compression, compressed_size, local_offset) in entries.items():
        local_header = _fetch_range(asset, local_offset, local_offset + 29)
        if local_header[:4] != b"PK\x03\x04":
            raise RuntimeError(f"Invalid ZIP local header for {archive_name}.")
        name_size, extra_size = struct.unpack_from("<2H", local_header, 26)
        data_offset = local_offset + 30 + name_size + extra_size
        compressed = _fetch_range(asset, data_offset, data_offset + compressed_size - 1)
        if compression == zipfile.ZIP_DEFLATED:
            contents[Path(archive_name).name] = zlib.decompress(compressed, -15)
        elif compression == zipfile.ZIP_STORED:
            contents[Path(archive_name).name] = compressed
        else:
            raise RuntimeError(
                f"Unsupported ZIP compression method {compression} for {archive_name}."
            )

    expected_hashes = {
        "METADATA": asset.metadata_sha256,
        "WHEEL": asset.wheel_metadata_sha256,
    }
    for name, expected_hash in expected_hashes.items():
        actual_hash = hashlib.sha256(contents[name]).hexdigest()
        if actual_hash != expected_hash:
            raise RuntimeError(
                f"SHA-256 mismatch for {asset.filename}!{name}: expected "
                f"{expected_hash}, received {actual_hash}."
            )
    return dist_info_directories.pop(), contents


def get_requires_for_build_wheel(config_settings=None) -> list[str]:
    return []


def prepare_metadata_for_build_wheel(metadata_directory, config_settings=None) -> str:
    asset = _select_asset()
    metadata_root = Path(metadata_directory).resolve()
    metadata_root.mkdir(parents=True, exist_ok=True)
    dist_info, contents = _remote_dist_info(asset)
    dist_info_directory = metadata_root / dist_info
    dist_info_directory.mkdir(parents=True, exist_ok=True)
    for name, content in contents.items():
        (dist_info_directory / name).write_bytes(content)
    return dist_info


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None) -> str:
    asset = _select_asset()
    output_directory = Path(wheel_directory).resolve()
    output_directory.mkdir(parents=True, exist_ok=True)
    _ensure_wheel(asset, output_directory)
    return asset.filename
