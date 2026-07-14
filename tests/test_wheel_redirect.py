from __future__ import annotations

import hashlib
import io
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import wheel_redirect


class SelectAssetTests(unittest.TestCase):
    def test_linux_cp312_x86_64(self) -> None:
        asset = wheel_redirect._select_asset(
            system="Linux",
            machine="x86_64",
            python_version=(3, 12),
            libc=("glibc", "2.34"),
        )
        self.assertIn("manylinux_2_34_x86_64", asset.filename)

    def test_windows_cp312_amd64(self) -> None:
        asset = wheel_redirect._select_asset(
            system="Windows", machine="AMD64", python_version=(3, 12)
        )
        self.assertTrue(asset.filename.endswith("win_amd64.whl"))

    def test_rejects_wrong_python(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "CPython 3.12"):
            wheel_redirect._select_asset(
                system="Linux", machine="x86_64", python_version=(3, 11)
            )

    def test_rejects_old_glibc(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "glibc 2.34 or newer"):
            wheel_redirect._select_asset(
                system="Linux",
                machine="x86_64",
                python_version=(3, 12),
                libc=("glibc", "2.31"),
            )

    def test_rejects_unsupported_os(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "Linux x86-64 and Windows x86-64"):
            wheel_redirect._select_asset(
                system="Darwin", machine="x86_64", python_version=(3, 12)
            )


class BackendTests(unittest.TestCase):
    @staticmethod
    def _fake_wheel() -> bytes:
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr(
                "pycolmap-4.1.0.dist-info/METADATA",
                "Metadata-Version: 2.1\nName: pycolmap\nVersion: 4.1.0\n",
            )
            archive.writestr(
                "pycolmap-4.1.0.dist-info/WHEEL",
                "Wheel-Version: 1.0\nTag: cp312-cp312-manylinux_2_34_x86_64\n",
            )
        return stream.getvalue()

    def test_prepare_metadata_then_build_downloads_wheel_once(self) -> None:
        wheel_bytes = self._fake_wheel()
        asset = wheel_redirect.WheelAsset(
            filename="pycolmap-4.1.0-cp312-cp312-manylinux_2_34_x86_64.whl",
            sha256=hashlib.sha256(wheel_bytes).hexdigest(),
            size=len(wheel_bytes),
            metadata_sha256=hashlib.sha256(
                b"Metadata-Version: 2.1\nName: pycolmap\nVersion: 4.1.0\n"
            ).hexdigest(),
            wheel_metadata_sha256=hashlib.sha256(
                b"Wheel-Version: 1.0\nTag: cp312-cp312-manylinux_2_34_x86_64\n"
            ).hexdigest(),
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            metadata = root / "metadata"
            wheelhouse = root / "wheelhouse"
            download_response = mock.MagicMock()
            download_response.__enter__.return_value = io.BytesIO(wheel_bytes)
            download_response.__exit__.return_value = False

            with (
                mock.patch.object(wheel_redirect, "_select_asset", return_value=asset),
                mock.patch.object(
                    wheel_redirect,
                    "_fetch_range",
                    side_effect=lambda _asset, start, end: wheel_bytes[start : end + 1],
                ),
                mock.patch.object(
                    wheel_redirect.urllib.request,
                    "urlopen",
                    return_value=download_response,
                ) as urlopen,
            ):
                dist_info = wheel_redirect.prepare_metadata_for_build_wheel(metadata)
                filename = wheel_redirect.build_wheel(wheelhouse)

            self.assertEqual(dist_info, "pycolmap-4.1.0.dist-info")
            self.assertEqual(filename, asset.filename)
            self.assertTrue((metadata / dist_info / "METADATA").is_file())
            self.assertEqual((wheelhouse / filename).read_bytes(), wheel_bytes)
            urlopen.assert_called_once()


if __name__ == "__main__":
    unittest.main()
