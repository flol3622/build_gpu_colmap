#!/usr/bin/env bash
set -Eeuo pipefail

# Build one self-contained pycolmap wheel against an actual manylinux baseline.
# This script is intended to run as root inside a PyPA manylinux container.

PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
CUDA_VERSION="${CUDA_VERSION:-12.8}"
MANYLINUX_TAG="${MANYLINUX_TAG:-manylinux_2_34_x86_64}"
BUNDLE_CUDA="${BUNDLE_CUDA:-true}"
WITH_CUDSS="${WITH_CUDSS:-true}"
CUDSS_VERSION="${CUDSS_VERSION:-0.7.1.4}"
# COLMAP 4.1.0 fetches ONNX Runtime 1.24.4's CUDA 12 provider.  Use cuDNN's
# compact JIT runtime: it supports CUDA 12.8 while avoiding the much larger
# precompiled-engine package.
ONNXRUNTIME_CUDNN_VERSION="${ONNXRUNTIME_CUDNN_VERSION:-9.10.2.21}"
BUILD_ROOT="${BUILD_ROOT:-/workspace/build-custom-wheel}"
WHEELHOUSE="${WHEELHOUSE:-/workspace/custom-wheelhouse}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

dump_recent_vcpkg_errors() {
  local status=$?
  if [[ $status -ne 0 && -d /workspace/third_party/vcpkg/buildtrees ]]; then
    echo "Recent vcpkg error logs:" >&2
    find /workspace/third_party/vcpkg/buildtrees \
      -type f -name '*err.log' -mmin -15 -print -exec tail -n 200 {} \; >&2 || true
  fi
  exit "$status"
}
trap dump_recent_vcpkg_errors ERR

as_bool() {
  case "${1,,}" in
    1|true|yes|on) echo true ;;
    0|false|no|off) echo false ;;
    *) die "Expected a boolean value, got: $1" ;;
  esac
}

BUNDLE_CUDA="$(as_bool "$BUNDLE_CUDA")"
WITH_CUDSS="$(as_bool "$WITH_CUDSS")"

case "$PYTHON_VERSION" in
  3.10|3.11|3.12|3.13|3.14) ;;
  *) die "Unsupported Python version: $PYTHON_VERSION" ;;
esac

case "$CUDA_VERSION" in
  12.8|13.0|13.1) ;;
  *) die "Unsupported CUDA version: $CUDA_VERSION" ;;
esac

case "$MANYLINUX_TAG" in
  manylinux_2_28_x86_64) EXPECTED_GLIBC="2.28" ;;
  manylinux_2_34_x86_64) EXPECTED_GLIBC="2.34" ;;
  *) die "Unsupported manylinux target: $MANYLINUX_TAG" ;;
esac
if [[ "$MANYLINUX_TAG" == manylinux_2_28_x86_64 && "$CUDA_VERSION" != 12.8 ]]; then
  die "The manylinux_2_28 builder is limited to the CUDA 12.8 family"
fi

cd /workspace
[[ -f CMakeLists.txt ]] || die "/workspace is not a build_gpu_colmap checkout"
[[ -f third_party/colmap-for-pycolmap/pyproject.toml ]] || \
  die "Submodules are missing; initialize them recursively before running the builder"

ACTUAL_GLIBC="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"
[[ "$ACTUAL_GLIBC" == "$EXPECTED_GLIBC" ]] || \
  die "Container glibc is $ACTUAL_GLIBC, but $MANYLINUX_TAG requires $EXPECTED_GLIBC"

PYTHON_TAG="${PYTHON_VERSION/./}"
PYTHON_BIN="/opt/python/cp${PYTHON_TAG}-cp${PYTHON_TAG}/bin/python"
[[ -x "$PYTHON_BIN" ]] || die "The selected manylinux image does not contain Python $PYTHON_VERSION"
export PATH="$(dirname "$PYTHON_BIN"):$PATH"

source /etc/os-release
OS_MAJOR="${VERSION_ID%%.*}"
case "$OS_MAJOR" in
  8|9) CUDA_REPO_DISTRO="rhel${OS_MAJOR}" ;;
  *) die "Unsupported manylinux base OS version: $VERSION_ID" ;;
esac

CUDA_PACKAGE_SUFFIX="${CUDA_VERSION/./-}"
CUDA_MAJOR="${CUDA_VERSION%%.*}"
CUDA_MINOR="${CUDA_VERSION#*.}"
CUDA_COMPACT="${CUDA_MAJOR}${CUDA_MINOR}"
CUDA_ROOT="/usr/local/cuda-${CUDA_VERSION}"

echo "Building pycolmap with:"
echo "  Python:       $PYTHON_VERSION"
echo "  CUDA:         $CUDA_VERSION"
echo "  cuDSS:        $WITH_CUDSS ($CUDSS_VERSION)"
echo "  ORT cuDNN:    $ONNXRUNTIME_CUDNN_VERSION (CUDA 12 JIT runtime)"
echo "  Bundle CUDA:  $BUNDLE_CUDA"
echo "  Platform:     $MANYLINUX_TAG (glibc $ACTUAL_GLIBC)"

dnf install -y dnf-plugins-core
dnf config-manager --add-repo \
  "https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO_DISTRO}/x86_64/cuda-${CUDA_REPO_DISTRO}.repo"
dnf clean all
ONNXRUNTIME_CUDA_PACKAGES=()
if [[ "$CUDA_MAJOR" -ge 13 ]]; then
  # ONNX Runtime 1.24.4's published Linux GPU provider is linked against the
  # CUDA 12 ABI even when the surrounding COLMAP build targets CUDA 13.
  ONNXRUNTIME_CUDA_PACKAGES+=(cuda-libraries-12-8)
fi
dnf install -y \
  autoconf automake bison curl flex git libtool make patch \
  kernel-headers perl-core perl-IPC-Cmd pkgconf-pkg-config tar unzip wget which xz zip \
  "cuda-compiler-${CUDA_PACKAGE_SUFFIX}" \
  "cuda-libraries-devel-${CUDA_PACKAGE_SUFFIX}" \
  "cuda-nvtx-${CUDA_PACKAGE_SUFFIX}" \
  "libcudnn9-jit-cuda-12-${ONNXRUNTIME_CUDNN_VERSION}-1" \
  "${ONNXRUNTIME_CUDA_PACKAGES[@]}"
dnf clean all

if [[ ! -x "$CUDA_ROOT/bin/nvcc" && -x /usr/local/cuda/bin/nvcc ]]; then
  CUDA_ROOT=/usr/local/cuda
fi
[[ -x "$CUDA_ROOT/bin/nvcc" ]] || die "nvcc was not installed under $CUDA_ROOT"
export CUDA_PATH="$CUDA_ROOT"
export PATH="$CUDA_ROOT/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_ROOT/lib64:$CUDA_ROOT/targets/x86_64-linux/lib:${LD_LIBRARY_PATH:-}"

python -m pip install --upgrade \
  "cmake>=3.28" ninja pip setuptools wheel \
  "scikit-build-core[pyproject]" "pybind11>=3.0.2" auditwheel patchelf

if [[ "$WITH_CUDSS" == true ]]; then
  CUDSS_ROOT=/opt/nvidia/cudss
  CUDSS_URL="https://developer.download.nvidia.com/compute/cudss/redist/libcudss/linux-x86_64/libcudss-linux-x86_64-${CUDSS_VERSION}_cuda${CUDA_MAJOR}-archive.tar.xz"
  echo "Installing cuDSS from $CUDSS_URL"
  curl --fail --location --retry 5 --retry-delay 5 "$CUDSS_URL" -o /tmp/cudss.tar.xz
  mkdir -p "$CUDSS_ROOT"
  tar -xf /tmp/cudss.tar.xz -C "$CUDSS_ROOT" --strip-components=1
  rm -f /tmp/cudss.tar.xz
  export CUDSS_ROOT

  for candidate in \
    "$CUDSS_ROOT/lib/$CUDA_MAJOR/cmake/cudss" \
    "$CUDSS_ROOT/lib64/$CUDA_MAJOR/cmake/cudss" \
    "$CUDSS_ROOT/lib/cmake/cudss" \
    "$CUDSS_ROOT/lib64/cmake/cudss"; do
    if [[ -d "$candidate" ]]; then
      CUDSS_DIR="$candidate"
      break
    fi
  done
  [[ -n "${CUDSS_DIR:-}" ]] || die "cuDSS CMake package was not found"

  for candidate in \
    "$CUDSS_ROOT/lib/$CUDA_MAJOR" "$CUDSS_ROOT/lib64/$CUDA_MAJOR" \
    "$CUDSS_ROOT/lib" "$CUDSS_ROOT/lib64"; do
    if compgen -G "$candidate/libcudss.so*" >/dev/null; then
      CUDSS_LIB_DIR="$candidate"
      break
    fi
  done
  [[ -n "${CUDSS_LIB_DIR:-}" ]] || die "cuDSS shared libraries were not found"
  export LD_LIBRARY_PATH="$CUDSS_LIB_DIR:$LD_LIBRARY_PATH"
fi

git config --global --add safe.directory /workspace
git config --global --add safe.directory /workspace/third_party/colmap-for-pycolmap
git config --global --add safe.directory /workspace/third_party/vcpkg
if git -C third_party/vcpkg rev-parse --is-shallow-repository | grep -Fx true >/dev/null; then
  git -C third_party/vcpkg fetch --unshallow
fi

PATCH_FILE=/workspace/patches/pycolmap-caspar-bindings.patch
if git -C third_party/colmap-for-pycolmap apply --check "$PATCH_FILE"; then
  git -C third_party/colmap-for-pycolmap apply "$PATCH_FILE"
elif git -C third_party/colmap-for-pycolmap apply --reverse --check "$PATCH_FILE"; then
  echo "pycolmap Caspar bindings patch is already applied"
elif git -C third_party/colmap-for-pycolmap grep -q \
  "BundleAdjustmentBackend::CASPAR" -- src/pycolmap/estimators/bundle_adjustment.cc; then
  echo "Upstream already contains the Caspar bindings"
else
  die "The pycolmap Caspar bindings patch cannot be applied"
fi

if [[ "$BUNDLE_CUDA" == true && "$WITH_CUDSS" == true ]]; then
  VERSION_SUFFIX="+cu${CUDA_COMPACT}.bundled.cudss"
elif [[ "$BUNDLE_CUDA" == true ]]; then
  VERSION_SUFFIX="+cu${CUDA_COMPACT}.bundled"
elif [[ "$WITH_CUDSS" == true ]]; then
  VERSION_SUFFIX="+cuda.cudss"
elif [[ "$CUDA_MAJOR" != 12 ]]; then
  VERSION_SUFFIX="+cu${CUDA_COMPACT}"
else
  VERSION_SUFFIX="+cuda"
fi

BASE_VERSION="$(python - <<'PY'
import pathlib, re
text = pathlib.Path("third_party/colmap-for-pycolmap/pyproject.toml").read_text()
match = re.search(r'^version = "([^"]+)"', text, re.MULTILINE)
if not match:
    raise SystemExit("pycolmap version not found")
print(match.group(1).split("+")[0])
PY
)"
export BASE_VERSION
WHEEL_VERSION="${BASE_VERSION}${VERSION_SUFFIX}"
export WHEEL_VERSION

rm -rf "$BUILD_ROOT" "$WHEELHOUSE"
mkdir -p "$BUILD_ROOT" "$WHEELHOUSE" /workspace/.cache/vcpkg
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"
export VCPKG_FORCE_SYSTEM_BINARIES=1
export VCPKG_BINARY_SOURCES="${VCPKG_BINARY_SOURCES:-clear;files,/workspace/.cache/vcpkg,readwrite}"

CMAKE_ARGS=(
  -S /workspace
  -B "$BUILD_ROOT"
  -G Ninja
  -DCMAKE_TOOLCHAIN_FILE=/workspace/third_party/vcpkg/scripts/buildsystems/vcpkg.cmake
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_CUDA_COMPILER="$CUDA_ROOT/bin/nvcc"
  -DCUDAToolkit_ROOT="$CUDA_ROOT"
  -DCUDA_TOOLKIT_ROOT_DIR="$CUDA_ROOT"
  -DCUDA_ENABLED=ON
  -DCASPAR_ENABLED=ON
  -DDOWNLOAD_ENABLED=ON
  -DBUILD_COLMAP=OFF
  -DBUILD_COLMAP_FOR_PYCOLMAP=ON
  -DBUILD_CERES=ON
  -DGFLAGS_USE_TARGET_NAMESPACE=ON
)
if [[ "$WITH_CUDSS" == true ]]; then
  CMAKE_ARGS+=("-Dcudss_DIR=$CUDSS_DIR")
fi

cmake "${CMAKE_ARGS[@]}"
cmake --build "$BUILD_ROOT" --config Release --parallel "$CMAKE_BUILD_PARALLEL_LEVEL"

COLMAP_INSTALL="$BUILD_ROOT/install/colmap-for-pycolmap"
CERES_INSTALL="$BUILD_ROOT/install/ceres"
VCPKG_INSTALLED="$BUILD_ROOT/vcpkg_installed"
PYBIND11_DIR="$(python -c 'import pybind11; print(pybind11.get_cmake_dir())')"
CMAKE_PREFIX_PATH="${COLMAP_INSTALL};${CERES_INSTALL};${PYBIND11_DIR}"

[[ -f "$COLMAP_INSTALL/share/colmap/colmap-targets.cmake" ]] || \
  die "COLMAP-for-pycolmap was not installed"
grep -q caspar_lib_core "$COLMAP_INSTALL/share/colmap/colmap-targets.cmake" || \
  die "Caspar is missing from the installed COLMAP targets"
COLMAP_CONFIG="$COLMAP_INSTALL/share/colmap/colmap-config.cmake"
[[ -f "$COLMAP_CONFIG" ]] || die "The installed COLMAP CMake package is missing"
grep -Eq '^set\(DOWNLOAD_ENABLED (ON|TRUE|1)\)$' "$COLMAP_CONFIG" || \
  die "COLMAP silently disabled DOWNLOAD_ENABLED"
if [[ "$WITH_CUDSS" == true ]]; then
  CERES_CONFIG="$(find "$CERES_INSTALL" -type f -name CeresConfig.cmake -print -quit)"
  [[ -f "$CERES_CONFIG" ]] || die "The installed Ceres CMake package is missing"
  grep -Eq '^set\(CERES_COMPILED_COMPONENTS ".*cuDSS' "$CERES_CONFIG" || \
    die "Ceres was not compiled with its cuDSS component"
  grep -Eq '^find_dependency\(cudss([ )])' "$CERES_CONFIG" || \
    die "The installed Ceres package does not export its cuDSS dependency"
fi

# The top-level ExternalProject patch deliberately restores the upstream
# release version while building COLMAP. Stamp the wheel metadata afterwards,
# immediately before invoking the isolated Python wheel build.
python - <<'PY'
import os, pathlib, re
path = pathlib.Path("third_party/colmap-for-pycolmap/pyproject.toml")
text = path.read_text()
updated, count = re.subn(
    r'^version = "[^"]+"',
    f'version = "{os.environ["WHEEL_VERSION"]}"',
    text,
    count=1,
    flags=re.MULTILINE,
)
if count != 1:
    raise SystemExit("Could not stamp the custom pycolmap version")
path.write_text(updated)
PY

pushd third_party/colmap-for-pycolmap >/dev/null
python -m pip wheel . --no-deps -w "$WHEELHOUSE/raw" \
  --config-settings="cmake.define.CMAKE_TOOLCHAIN_FILE=/workspace/third_party/vcpkg/scripts/buildsystems/vcpkg.cmake" \
  --config-settings="cmake.define.VCPKG_INSTALLED_DIR=${VCPKG_INSTALLED}" \
  --config-settings="cmake.define.CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}" \
  --config-settings="cmake.define.VCPKG_TARGET_TRIPLET=x64-linux" \
  --config-settings="cmake.define.cudss_DIR=${CUDSS_DIR:-}" \
  --config-settings="cmake.define.CUDA_ENABLED=OFF" \
  --config-settings="cmake.define.CMAKE_CUDA_COMPILER=${CUDA_ROOT}/bin/nvcc" \
  --config-settings="cmake.define.CUDAToolkit_ROOT=${CUDA_ROOT}" \
  --config-settings="cmake.define.CUDA_TOOLKIT_ROOT_DIR=${CUDA_ROOT}"
popd >/dev/null

RAW_WHEEL="$(find "$WHEELHOUSE/raw" -maxdepth 1 -name '*.whl' -print -quit)"
[[ -n "$RAW_WHEEL" ]] || die "The raw pycolmap wheel was not created"

export LD_LIBRARY_PATH="${VCPKG_INSTALLED}/x64-linux/lib:${COLMAP_INSTALL}/lib:${COLMAP_INSTALL}/lib64:${CERES_INSTALL}/lib:${CERES_INSTALL}/lib64:$LD_LIBRARY_PATH"

# ONNX Runtime discovers execution providers and cuDNN engine libraries with
# dlopen(), so they are not reachable from pycolmap's normal DT_NEEDED graph.
# Put them in the raw wheel before auditwheel runs: this lets auditwheel repair
# the provider's CUDA dependencies and patch their names/rpaths consistently.
ORT_PROVIDER_DIR=""
for candidate in "$COLMAP_INSTALL/lib" "$COLMAP_INSTALL/lib64"; do
  if [[ -f "$candidate/libonnxruntime_providers_shared.so" && \
        -f "$candidate/libonnxruntime_providers_cuda.so" ]]; then
    ORT_PROVIDER_DIR="$candidate"
    break
  fi
done
if [[ -z "$ORT_PROVIDER_DIR" ]]; then
  find "$COLMAP_INSTALL" -name 'libonnxruntime_providers_*.so' -print >&2 || true
  die "ONNX Runtime shared and CUDA providers were not installed under $COLMAP_INSTALL/lib{,64}"
fi

CUDNN_RUNTIME_LIBS=()
if [[ "$BUNDLE_CUDA" == true ]]; then
  for name in \
    libcudnn.so.9 \
    libcudnn_graph.so.9 \
    libcudnn_engines_runtime_compiled.so.9; do
    library=""
    for candidate in "/usr/lib64/$name" "/usr/lib/$name"; do
      if [[ -f "$candidate" ]]; then
        library="$candidate"
        break
      fi
    done
    [[ -n "$library" ]] || die "The cuDNN JIT runtime is missing $name"
    CUDNN_RUNTIME_LIBS+=("$library")
  done
fi

INJECT_DIR="$(mktemp -d)"
python -m wheel unpack "$RAW_WHEEL" -d "$INJECT_DIR"
RAW_WHEEL_DIR="$(find "$INJECT_DIR" -mindepth 1 -maxdepth 1 -type d -name 'pycolmap-*' -print -quit)"
[[ -n "$RAW_WHEEL_DIR" ]] || die "Could not locate the unpacked raw wheel"
RAW_LIBS_DIR="$(find "$RAW_WHEEL_DIR" -type d -name '*.libs' -print -quit)"
if [[ -z "$RAW_LIBS_DIR" ]]; then
  RAW_LIBS_DIR="$RAW_WHEEL_DIR/pycolmap.libs"
  mkdir -p "$RAW_LIBS_DIR"
fi

cp "$ORT_PROVIDER_DIR/libonnxruntime_providers_shared.so" "$RAW_LIBS_DIR/"
cp "$ORT_PROVIDER_DIR/libonnxruntime_providers_cuda.so" "$RAW_LIBS_DIR/"
for library in "${CUDNN_RUNTIME_LIBS[@]}"; do
  cp -L "$library" "$RAW_LIBS_DIR/$(basename "$library")"
done
for library in \
  "$RAW_LIBS_DIR/libonnxruntime_providers_shared.so" \
  "$RAW_LIBS_DIR/libonnxruntime_providers_cuda.so"; do
  patchelf --set-rpath '$ORIGIN' "$library"
done
for library in "$RAW_LIBS_DIR"/libcudnn*.so.9; do
  [[ -f "$library" ]] && patchelf --set-rpath '$ORIGIN' "$library"
done

rm -f "$RAW_WHEEL"
python -m wheel pack "$RAW_WHEEL_DIR" -d "$WHEELHOUSE/raw"
rm -rf "$INJECT_DIR"
RAW_WHEEL="$(find "$WHEELHOUSE/raw" -maxdepth 1 -name '*.whl' -print -quit)"
[[ -n "$RAW_WHEEL" ]] || die "The ONNX-injected raw wheel was not created"

EXCLUDE_ARGS=(--exclude libcuda.so.1)
if [[ "$BUNDLE_CUDA" == false ]]; then
  EXCLUDE_ARGS+=(
    --exclude libcudart.so.12 --exclude libcudart.so.13
    --exclude libcublas.so.12 --exclude libcublas.so.13
    --exclude libcublasLt.so.12 --exclude libcublasLt.so.13
    --exclude libcufft.so.11 --exclude libcurand.so.10
    --exclude libcusolver.so.11 --exclude libcusparse.so.12
    --exclude libnvJitLink.so.12 --exclude libnvJitLink.so.13
    --exclude libnvrtc.so.12 --exclude libnvrtc.so.13
    --exclude libcudnn.so.9
    --exclude libcudnn_graph.so.9
    --exclude libcudnn_engines_runtime_compiled.so.9
    --exclude libcudss.so.0
  )
fi

auditwheel show "$RAW_WHEEL"
auditwheel repair "$RAW_WHEEL" -w "$WHEELHOUSE" \
  --plat "$MANYLINUX_TAG" "${EXCLUDE_ARGS[@]}"
rm -rf "$WHEELHOUSE/raw"

REPAIRED_WHEEL="$(find "$WHEELHOUSE" -maxdepth 1 -name '*.whl' -print -quit)"
[[ -n "$REPAIRED_WHEEL" ]] || die "auditwheel did not create a repaired wheel"

EXPECTED_NAME="pycolmap-${WHEEL_VERSION}-cp${PYTHON_TAG}-cp${PYTHON_TAG}-${MANYLINUX_TAG}.whl"
[[ "$(basename "$REPAIRED_WHEEL")" == "$EXPECTED_NAME" ]] || \
  die "Unexpected wheel name: $(basename "$REPAIRED_WHEEL"); expected $EXPECTED_NAME"
unzip -p "$REPAIRED_WHEEL" '*dist-info/METADATA' | \
  grep -Fx "Version: $WHEEL_VERSION" >/dev/null || die "Wheel METADATA has the wrong version"

for library in \
  libonnxruntime_providers_shared.so \
  libonnxruntime_providers_cuda.so; do
  unzip -Z1 "$REPAIRED_WHEEL" | grep -F "/$library" >/dev/null || \
    die "Repaired wheel does not contain $library"
done

if [[ "$BUNDLE_CUDA" == true ]]; then
  unzip -l "$REPAIRED_WHEEL" | grep -E 'libcudart[^/]*\.so' >/dev/null || \
    die "Bundled CUDA wheel does not contain libcudart"
  unzip -l "$REPAIRED_WHEEL" | grep -E 'libcufft[^/]*\.so' >/dev/null || \
    die "Bundled CUDA wheel does not contain libcufft"
  for library in \
    libcudnn.so.9 \
    libcudnn_graph.so.9 \
    libcudnn_engines_runtime_compiled.so.9; do
    unzip -Z1 "$REPAIRED_WHEEL" | grep -F "/$library" >/dev/null || \
      die "Bundled CUDA wheel does not contain $library"
  done
fi
if [[ "$WITH_CUDSS" == true && "$BUNDLE_CUDA" == true ]]; then
  unzip -l "$REPAIRED_WHEEL" | grep -E 'libcudss[^/]*\.so' >/dev/null || \
    die "Bundled cuDSS wheel does not contain libcudss"
fi

auditwheel show "$REPAIRED_WHEEL"
python -m pip install --force-reinstall "$REPAIRED_WHEEL"
python - <<'PY'
import importlib.metadata
import os
import subprocess
from pathlib import Path

import pycolmap

assert pycolmap.__version__ == os.environ["BASE_VERSION"]
assert importlib.metadata.version("pycolmap") == os.environ["WHEEL_VERSION"]
assert pycolmap.BundleAdjustmentBackend.CASPAR == pycolmap.BundleAdjustmentBackend("CASPAR")
options = pycolmap.BundleAdjustmentOptions()
options.backend = pycolmap.BundleAdjustmentBackend.CASPAR
assert isinstance(options.caspar, pycolmap.CasparBundleAdjustmentOptions)

libs_dir = Path(pycolmap.__file__).resolve().parent.parent / "pycolmap.libs"
for name in (
    "libonnxruntime_providers_shared.so",
    "libonnxruntime_providers_cuda.so",
):
    provider = libs_dir / name
    assert provider.is_file(), f"missing ONNX Runtime provider: {provider}"
    # Do not dlopen the CUDA provider on GitHub's driverless runner: its static
    # initializers enter CUDA and can segfault without a display driver. ldd
    # resolves the complete DT_NEEDED graph without running those initializers.
    result = subprocess.run(
        ["ldd", str(provider)], capture_output=True, text=True, check=False
    )
    dependencies = result.stdout + result.stderr
    assert result.returncode == 0, dependencies
    assert "not found" not in dependencies, dependencies

print(f"Smoke test passed for pycolmap {pycolmap.__version__}")
PY

ALIKED_TEST_HOME="$(mktemp -d)"
HOME="$ALIKED_TEST_HOME" python .github/scripts/validate_aliked_download.py
rm -rf "$ALIKED_TEST_HOME"

# A wheel that genuinely satisfies the 2.34 baseline is also valid with the
# stricter 2.35 tag. Emit both distribution filenames while keeping the wheel
# metadata and RECORD correct; `wheel tags` performs the metadata rewrite.
if [[ "$MANYLINUX_TAG" == manylinux_2_34_x86_64 ]]; then
  python -m wheel tags \
    --platform-tag manylinux_2_35_x86_64 \
    "$REPAIRED_WHEEL"
  COMPATIBLE_NAME="pycolmap-${WHEEL_VERSION}-cp${PYTHON_TAG}-cp${PYTHON_TAG}-manylinux_2_35_x86_64.whl"
  COMPATIBLE_WHEEL="$WHEELHOUSE/$COMPATIBLE_NAME"
  [[ -f "$COMPATIBLE_WHEEL" ]] || die "The manylinux_2_35 wheel was not emitted"
  unzip -p "$COMPATIBLE_WHEEL" '*dist-info/METADATA' | \
    grep -Fx "Version: $WHEEL_VERSION" >/dev/null || \
    die "The manylinux_2_35 wheel METADATA has the wrong version"
  unzip -p "$COMPATIBLE_WHEEL" '*dist-info/WHEEL' | \
    grep -Fx "Tag: cp${PYTHON_TAG}-cp${PYTHON_TAG}-manylinux_2_35_x86_64" >/dev/null || \
    die "The manylinux_2_35 wheel has the wrong internal platform tag"
fi

ACTUAL_CUDA_VERSION="$(nvcc --version | sed -n 's/.*release \([0-9.]*\).*/\1/p' | head -n 1)"
BUILD_INFO="$WHEELHOUSE/${EXPECTED_NAME%.whl}.build_info.json"
CUDSS_BUILD_VERSION=""
if [[ "$WITH_CUDSS" == true ]]; then
  CUDSS_BUILD_VERSION="$CUDSS_VERSION"
fi
if [[ "$CUDA_MAJOR" -ge 13 ]]; then
  CUDA_ARCHITECTURES='75;80;86;89;90;120'
else
  CUDA_ARCHITECTURES='75;80;86;89;90'
fi
python scripts/emit_build_info.py \
  --output "$BUILD_INFO" \
  --colmap-dir third_party/colmap-for-pycolmap \
  --os "$MANYLINUX_TAG" \
  --variant "pycolmap $WHEEL_VERSION" \
  --cuda-version "${ACTUAL_CUDA_VERSION:-$CUDA_VERSION}" \
  --cudss-version "$CUDSS_BUILD_VERSION" \
  --caspar true \
  --cudss "$WITH_CUDSS" \
  --gui false \
  --cuda-arch "$CUDA_ARCHITECTURES"

echo "Built and validated: $REPAIRED_WHEEL"
