# vcpkg Overlay Ports

This directory contains local port overrides for vcpkg packages that require patches.

## Purpose

Overlay ports allow us to patch vcpkg packages without modifying the vcpkg submodule itself. This keeps the submodule clean and makes it easy to update vcpkg independently.

## Current Patches

### ceres

**Issue:** CUDA feature propagation through dependency chain - When Ceres's suitesparse feature is enabled, it requests suitesparse-cholmod and suitesparse-spqr without CUDA features, preventing SuiteSparse from being built with CUDA support even when the root project explicitly requests it.

**Root Cause:** vcpkg's feature resolution algorithm prioritizes direct dependency specifications over meta-package features. When Ceres directly requests suitesparse-cholmod[matrixops] and suitesparse-spqr (without cuda), this overrides the root project's request for suitesparse[cuda].

**Fix:** Modified Ceres's suitesparse feature to explicitly request CUDA features for SuiteSparse components:
- suitesparse-cholmod: Added "cuda" to features list (now ["matrixops", "cuda"])
- suitesparse-spqr: Added "cuda" to features list

**Modified Files:**
- `ceres/vcpkg.json` - Lines 54-63: Add cuda features to suitesparse dependencies
- `ceres/portfile.cmake` - Copied from baseline (no modifications)
- `ceres/*.patch` - Copied from baseline (no modifications)

**Impact:** This ensures that when Ceres is built with SuiteSparse support, the SuiteSparse libraries will inherit CUDA support if available on the platform (respecting platform support constraints defined in each component).

**Note:** Overlay ports require ALL files from the original port (portfile.cmake, patches, etc.), not just the modified vcpkg.json. The portfile.cmake and patch files are copied from the baseline vcpkg port without modifications.

### suitesparse-spqr and suitesparse-cholmod

**Issue:** vcpkg bug #44797 - CMAKE_CUDA_ARCHITECTURES is empty when building with CUDA support, causing build failures.

**Fix:** Set default CUDA architectures to support modern NVIDIA GPUs:
- 75: Turing (RTX 20xx, GTX 16xx)
- 80: Ampere (A100 data center)
- 86: Ampere (RTX 30xx GeForce)
- 89: Ada Lovelace (RTX 40xx)
- 90: Hopper (H100 data center)
- 120: Blackwell (RTX 50xx)

**Modified Files:**
- `suitesparse-spqr/portfile.cmake` - Lines 27-32: Add CUDA_ARCHITECTURES default
- `suitesparse-cholmod/portfile.cmake` - Lines 35-40: Add CUDA_ARCHITECTURES default

### openblas

**Issue:** OpenBLAS is compiled for the CPU of whichever machine happens to run the build, which caused two distinct problems on shared CI runners:

1. **Intermittent build failures.** Linux pycolmap jobs failed at `vcpkg install` with:
   ```
   error: inlining failed in call to 'always_inline'
          '_mm512_castps512_ps128': target specific option mismatch
   ```
   Identical configurations passed or failed depending only on which runner they landed on.

2. **Non-portable artifacts.** Wheels built on an AVX-512 runner can execute AVX-512 instructions on a user's older CPU and die with `SIGILL`. This shipped silently — nothing fails at build time when the flags happen to line up.

**Root Cause:** On a native build the port runs OpenBLAS's `getarch`, which probes the build host's CPU and writes `HAVE_AVX512VL` / `HAVE_AVX512BF16` into `config.h`. `kernel/simd/intrin.h` includes `intrin_avx512.h` based solely on those defines:

```c
#if defined(HAVE_AVX512VL) || defined(HAVE_AVX512BF16)
#include "intrin_avx512.h"
```

but no matching `-mavx512*` flag is added for the generic kernels. GCC declares every `_mm512_*` intrinsic as `target("avx512f")` + `always_inline`, and inlining one into a caller lacking that target option is a hard error rather than a fallback. Confirmed against the failing job log: `-mavx512` appears zero times in the entire build.

**Fix:** Force `TARGET`, which makes `getarch` run with `-DFORCE_<TARGET>` instead of probing, so `config.h` is byte-identical on every runner. `PRESCOTT` is OpenBLAS's conventional x86-64 baseline and only sets the floor for common/driver code. The `dynamic-arch` feature (requested from the root `vcpkg.json`) then builds every kernel variant — Haswell, SkylakeX, Zen, etc. — each with its own correct flags, dispatching on the *user's* CPU at runtime. Pinning the baseline therefore costs no kernel performance.

**Modified Files:**
- `openblas/portfile.cmake` - Adds `-DTARGET=PRESCOTT` for non-Windows x64
- `openblas/vcpkg.json` - `port-version: 1` (forces an ABI change so stale binary-cache entries are not reused)
- `../vcpkg.json` - Requests `openblas[dynamic-arch]` gated to `!windows`

**Windows:** unaffected and unchanged. `dynamic-arch` is `"supports": "!windows | mingw"`, so it cannot be enabled under MSVC, and the `TARGET` pin is gated off there deliberately — pinning without runtime dispatch would be a straight performance loss. Windows keeps upstream host-detection behaviour; it does not suffer problem (1), and problem (2) remains open there.

## How It Works

The CMakeLists.txt sets `VCPKG_OVERLAY_PORTS` to point to this directory before calling `project()`. When vcpkg resolves package names, it checks overlay ports first, so our patched versions take priority over the baseline vcpkg registry.

## Updating Patches

If vcpkg is updated and these patches are no longer needed (or need to be updated):

1. Check if the issue is fixed upstream in vcpkg
2. Update the portfile.cmake files in this directory as needed
3. Test the build to ensure it works
4. Update this README with any changes

## References

- vcpkg overlay-ports documentation: https://learn.microsoft.com/en-us/vcpkg/users/examples/overlay-ports-versioning
- vcpkg issue #44797: https://github.com/microsoft/vcpkg/issues/44797
