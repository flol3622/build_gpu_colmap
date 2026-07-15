from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stamp = load_script(
    "stamp_pycolmap_wheel", ROOT / ".github/scripts/stamp_pycolmap_wheel.py"
)
release = load_script(
    "update_release_wheels", ROOT / "scripts/update_release_wheels.py"
)


class StampPycolmapWheelTests(unittest.TestCase):
    def test_stamps_version_and_external_runtime_dependencies(self) -> None:
        original = """\
[build-system]
requires = ["wheel"]

[project]
name = "pycolmap"
version = "4.1.0"
dependencies = ["numpy"]

[tool.test]
enabled = true
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pyproject.toml"
            path.write_text(original, encoding="utf-8")
            stamp.stamp_pyproject(
                path,
                "4.1.0+cu128.pipcuda.cudss",
                external_nvidia_runtime=True,
                with_cudss=True,
            )
            result = path.read_text(encoding="utf-8")

        self.assertIn('version = "4.1.0+cu128.pipcuda.cudss"', result)
        for requirement in stamp.NVIDIA_RUNTIME_REQUIREMENTS:
            self.assertIn(requirement, result)
        self.assertIn(stamp.CUDSS_REQUIREMENT, result)
        self.assertIn("[tool.test]", result)

    def test_bundled_build_only_stamps_version(self) -> None:
        original = """\
[project]
name = "pycolmap"
version = "4.1.0"
dependencies = ["numpy"]

[tool.test]
enabled = true
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pyproject.toml"
            path.write_text(original, encoding="utf-8")
            stamp.stamp_pyproject(
                path,
                "4.1.0+cu128.bundled",
                external_nvidia_runtime=False,
                with_cudss=False,
            )
            result = path.read_text(encoding="utf-8")

        self.assertIn('dependencies = ["numpy"]', result)
        self.assertNotIn("nvidia-", result)


class ReleaseManifestTests(unittest.TestCase):
    @staticmethod
    def make_wheel(path: Path, tag: str) -> None:
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(
                "pycolmap-4.1.0.dist-info/METADATA",
                "Metadata-Version: 2.1\nName: pycolmap\nVersion: 4.1.0\n",
            )
            archive.writestr(
                "pycolmap-4.1.0.dist-info/WHEEL",
                f"Wheel-Version: 1.0\nTag: {tag}\n",
            )

    def test_describes_release_wheels(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            linux = root / "pycolmap-test-cp312-cp312-manylinux_2_34_x86_64.whl"
            windows = root / "pycolmap-test-cp312-cp312-win_amd64.whl"
            self.make_wheel(linux, "cp312-cp312-manylinux_2_34_x86_64")
            self.make_wheel(windows, "cp312-cp312-win_amd64")

            manifest = {
                "release_tag": "test-r3",
                "assets": {
                    "linux": release.describe_wheel(linux),
                    "windows": release.describe_wheel(windows),
                },
            }
            encoded = json.dumps(manifest)
            linux_size = linux.stat().st_size

        self.assertIn('"release_tag": "test-r3"', encoded)
        self.assertEqual(manifest["assets"]["linux"]["size"], linux_size)
        self.assertEqual(len(manifest["assets"]["windows"]["sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
