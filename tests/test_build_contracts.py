"""Regression checks for the fixed GPU wheel build contracts."""

from __future__ import annotations

import ctypes
import importlib
import os
import platform
import shutil
import subprocess
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
PRELOAD_PATCH = ROOT / "patches/pycolmap-nvidia-runtime-preload.patch"
WINDOWS_WORKFLOW = ROOT / ".github/workflows/build-windows-pycolmap.yml"
LINUX_BUILDER = ROOT / ".github/scripts/build_manylinux_wheel.sh"


class NvidiaRuntimePreloadContractTests(unittest.TestCase):
    @staticmethod
    def _patched_preloader_namespace(root: Path) -> dict[str, object]:
        source_root = root / "source"
        init_path = source_root / "python/pycolmap/__init__.py"
        init_path.parent.mkdir(parents=True)
        shutil.copyfile(
            ROOT / "third_party/colmap-for-pycolmap/python/pycolmap/__init__.py",
            init_path,
        )
        result = subprocess.run(
            ["git", "apply", "--unsafe-paths", str(PRELOAD_PATCH)],
            cwd=source_root,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        preloader_source = init_path.read_text().split("\n_preload_cuda_deps()\n", 1)[0]
        preloader_source = preloader_source.replace(
            "from .utils import import_module_symbols\n", ""
        )
        namespace: dict[str, object] = {}
        exec(compile(preloader_source, str(init_path), "exec"), namespace)
        return namespace

    def test_patch_applies_to_pinned_pycolmap(self) -> None:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(ROOT / "third_party/colmap-for-pycolmap"),
                "apply",
                "--check",
                str(PRELOAD_PATCH),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_patch_matches_pinned_nvidia_wheel_layouts(self) -> None:
        patch = PRELOAD_PATCH.read_text()
        self.assertIn('("nvidia.cu12", ("libcudss.so.0",)', patch)
        self.assertNotIn("nvidia.cudss", patch)
        self.assertIn('("nvJitLink_*.dll",)', patch)
        self.assertIn('"nvrtc64_*_0.dll"', patch)
        self.assertNotIn('"nvrtc64_*.dll"', patch)
        self.assertIn('"libnvrtc-builtins.so.*[0-9]"', patch)
        self.assertIn("has no library matching", patch)

    def test_windows_preloader_resolves_every_pinned_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_dir:
            root = Path(temporary_dir)
            namespace = self._patched_preloader_namespace(root)
            package_files = {
                "nvidia.cuda_runtime": ("cudart64_12.dll",),
                "nvidia.nvjitlink": ("nvJitLink_120_0.dll",),
                "nvidia.cuda_nvrtc": (
                    "nvrtc-builtins64_128.dll",
                    "nvrtc64_120_0.alt.dll",
                    "nvrtc64_120_0.dll",
                ),
                "nvidia.cublas": ("cublasLt64_12.dll", "cublas64_12.dll"),
                "nvidia.cufft": ("cufft64_11.dll",),
                "nvidia.curand": ("curand64_10.dll",),
                "nvidia.cusparse": ("cusparse64_12.dll",),
                "nvidia.cusolver": ("cusolver64_11.dll",),
                "nvidia.cudnn": (
                    "cudnn64_9.dll",
                    "cudnn_ops64_9.dll",
                    "cudnn_adv64_9.dll",
                    "cudnn_cnn64_9.dll",
                    "cudnn_graph64_9.dll",
                    "cudnn_heuristic64_9.dll",
                    "cudnn_engines_precompiled64_9.dll",
                    "cudnn_engines_runtime_compiled64_9.dll",
                ),
                "nvidia.cu12": ("cudss64_0.dll",),
            }
            modules = {}
            for module_name, filenames in package_files.items():
                package_dir = root / module_name.replace(".", "/")
                bin_dir = package_dir / "bin"
                bin_dir.mkdir(parents=True)
                for filename in filenames:
                    (bin_dir / filename).touch()
                modules[module_name] = types.SimpleNamespace(
                    __file__=None, __path__=[str(package_dir)]
                )

            def import_module(module_name: str):
                if module_name == "nvidia.nvtx":
                    return types.SimpleNamespace(__file__=None, __path__=[])
                return modules[module_name]

            handles = []

            def load_library(path: str):
                handle = types.SimpleNamespace(_name=path)
                handles.append(handle)
                return handle

            with (
                mock.patch.object(importlib, "import_module", side_effect=import_module),
                mock.patch.object(platform, "system", return_value="Windows"),
                mock.patch.object(ctypes, "WinDLL", side_effect=load_library, create=True),
                mock.patch.object(os, "add_dll_directory", side_effect=lambda path: path, create=True),
            ):
                namespace["_preload_cuda_deps"]()

            loaded_names = {Path(handle._name).name for handle in handles}
            self.assertEqual(len(handles), 19)
            self.assertIn("cudss64_0.dll", loaded_names)
            self.assertIn("nvJitLink_120_0.dll", loaded_names)
            self.assertIn("nvrtc64_120_0.dll", loaded_names)
            self.assertNotIn("nvrtc64_120_0.alt.dll", loaded_names)

    def test_windows_wheel_preserves_onnx_cuda_providers(self) -> None:
        workflow = WINDOWS_WORKFLOW.read_text()
        for provider in (
            "onnxruntime_providers_shared.dll",
            "onnxruntime_providers_cuda.dll",
        ):
            self.assertGreaterEqual(workflow.count(provider), 3)
        self.assertIn("--include $providerDllList", workflow)
        self.assertIn("--no-mangle $providerDllList", workflow)

    def test_smoke_tests_hide_build_runtime_paths(self) -> None:
        windows = WINDOWS_WORKFLOW.read_text()
        linux = LINUX_BUILDER.read_text()
        self.assertIn("NVIDIA GPU Computing Toolkit", windows)
        self.assertIn('Remove-Item Env:CUDSS_ROOT', windows)
        self.assertIn('package_root("nvidia.cu12")', windows)
        self.assertIn("env -u LD_LIBRARY_PATH python - <<'PY'", linux)
        self.assertIn('importlib.import_module("nvidia.cu12")', linux)
        self.assertIn('"libnvrtc.alt.so.12" not in loaded_names', linux)
        self.assertIn(
            'env -u LD_LIBRARY_PATH HOME="$ALIKED_TEST_HOME"', linux
        )


if __name__ == "__main__":
    unittest.main()
