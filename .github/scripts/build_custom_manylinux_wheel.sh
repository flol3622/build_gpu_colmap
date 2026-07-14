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
echo "  Bundle CUDA:  $BUNDLE_CUDA"
echo "  Platform:     $MANYLINUX_TAG (glibc $ACTUAL_GLIBC)"

dnf install -y dnf-plugins-core
dnf config-manager --add-repo \
  "https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO_DISTRO}/x86_64/cuda-${CUDA_REPO_DISTRO}.repo"
dnf clean all
dnf install -y \
  autoconf automake bison curl flex git libtool make patch \
  kernel-headers perl-core perl-IPC-Cmd pkgconf-pkg-config tar unzip wget which xz zip \
  "cuda-compiler-${CUDA_PACKAGE_SUFFIX}" \
  "cuda-libraries-devel-${CUDA_PACKAGE_SUFFIX}" \
  "cuda-nvtx-${CUDA_PACKAGE_SUFFIX}"
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
WHEEL_VERSION="${BASE_VERSION}${VERSION_SUFFIX}"
export WHEEL_VERSION
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

export LD_LIBRARY_PATH="${VCPKG_INSTALLED}/x64-linux/lib:${COLMAP_INSTALL}/lib:${CERES_INSTALL}/lib:$LD_LIBRARY_PATH"
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
    --exclude libcudss.so.0
  )
fi

auditwheel show "$RAW_WHEEL"
auditwheel repair "$RAW_WHEEL" -w "$WHEELHOUSE" \
  --plat "$MANYLINUX_TAG" "${EXCLUDE_ARGS[@]}"
rm -rf "$WHEELHOUSE/raw"

REPAIRED_WHEEL="$(find "$WHEELHOUSE" -maxdepth 1 -name '*.whl' -print -quit)"
[[ -n "$REPAIRED_WHEEL" ]] || die "auditwheel did not create a repaired wheel"

# ONNX Runtime loads these providers with dlopen(), so auditwheel cannot
# discover them through the normal DT_NEEDED graph. Keep the upstream build's
# explicit provider injection behavior.
if [[ -f "$COLMAP_INSTALL/lib/libonnxruntime_providers_shared.so" ]]; then
  TMPDIR="$(mktemp -d)"
  python -m wheel unpack "$REPAIRED_WHEEL" -d "$TMPDIR"
  WHEEL_DIR="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -name 'pycolmap-*' -print -quit)"
  LIBS_DIR="$(find "$WHEEL_DIR" -type d -name '*.libs' -print -quit)"
  if [[ -z "$LIBS_DIR" ]]; then
    LIBS_DIR="$WHEEL_DIR/pycolmap.libs"
    mkdir -p "$LIBS_DIR"
  fi
  cp "$COLMAP_INSTALL/lib/libonnxruntime_providers_shared.so" "$LIBS_DIR/"
  cp "$COLMAP_INSTALL/lib/libonnxruntime_providers_cuda.so" "$LIBS_DIR/"
  RENAMED_ORT="$(find "$LIBS_DIR" -maxdepth 1 -name 'libonnxruntime-*.so.*' -print -quit)"
  if [[ -n "$RENAMED_ORT" ]]; then
    ln -sfn "$(basename "$RENAMED_ORT")" "$LIBS_DIR/libonnxruntime.so.1"
  fi
  patchelf --set-rpath '$ORIGIN' "$LIBS_DIR/libonnxruntime_providers_shared.so"
  patchelf --set-rpath '$ORIGIN' "$LIBS_DIR/libonnxruntime_providers_cuda.so"
  rm -f "$REPAIRED_WHEEL"
  python -m wheel pack "$WHEEL_DIR" -d "$WHEELHOUSE"
  rm -rf "$TMPDIR"
  REPAIRED_WHEEL="$(find "$WHEELHOUSE" -maxdepth 1 -name '*.whl' -print -quit)"
fi

EXPECTED_NAME="pycolmap-${WHEEL_VERSION}-cp${PYTHON_TAG}-cp${PYTHON_TAG}-${MANYLINUX_TAG}.whl"
[[ "$(basename "$REPAIRED_WHEEL")" == "$EXPECTED_NAME" ]] || \
  die "Unexpected wheel name: $(basename "$REPAIRED_WHEEL"); expected $EXPECTED_NAME"
unzip -p "$REPAIRED_WHEEL" '*dist-info/METADATA' | \
  grep -Fx "Version: $WHEEL_VERSION" >/dev/null || die "Wheel METADATA has the wrong version"

if [[ "$BUNDLE_CUDA" == true ]]; then
  unzip -l "$REPAIRED_WHEEL" | grep -E 'libcudart[^/]*\.so' >/dev/null || \
    die "Bundled CUDA wheel does not contain libcudart"
fi
if [[ "$WITH_CUDSS" == true && "$BUNDLE_CUDA" == true ]]; then
  unzip -l "$REPAIRED_WHEEL" | grep -E 'libcudss[^/]*\.so' >/dev/null || \
    die "Bundled cuDSS wheel does not contain libcudss"
fi

auditwheel show "$REPAIRED_WHEEL"
python -m pip install --force-reinstall "$REPAIRED_WHEEL"
python - <<'PY'
import os
import pycolmap

assert pycolmap.__version__ == os.environ["WHEEL_VERSION"]
assert pycolmap.BundleAdjustmentBackend.CASPAR == pycolmap.BundleAdjustmentBackend("CASPAR")
options = pycolmap.BundleAdjustmentOptions()
options.backend = pycolmap.BundleAdjustmentBackend.CASPAR
assert isinstance(options.caspar, pycolmap.CasparBundleAdjustmentOptions)
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
