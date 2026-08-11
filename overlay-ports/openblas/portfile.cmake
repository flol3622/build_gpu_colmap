vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO OpenMathLib/OpenBLAS
    REF "v${VERSION}"
    SHA512 046316b4297460bffca09c890ecad17ea39d8b3db92ff445d03b547dd551663d37e40f38bce8ae11e2994374ff01e622b408da27aa8e40f4140185ee8f001a60
    HEAD_REF develop
    PATCHES
        disable-testing.diff
        getarch.diff
        system-check-msvc.diff
        win32-uwp.diff
)

vcpkg_check_features(OUT_FEATURE_OPTIONS OPTIONS
    FEATURES
        threads        USE_THREAD
        simplethread   USE_SIMPLE_THREADED_LEVEL3
        dynamic-arch   DYNAMIC_ARCH
)

# If not explicitly configured for a cross build, OpenBLAS wants to run 
# getarch executables in order to optimize for the target.
# Adapting this to vcpkg triplets:
# - install-getarch.diff introduces and uses GETARCH_BINARY_DIR,
# - architecture and system name are required to match for GETARCH_BINARY_DIR, but
# - uwp (aka WindowsStore) may run windows getarch.
string(REPLACE "WindowsStore_" "_" SYSTEM_KEY "${VCPKG_CMAKE_SYSTEM_NAME}_${VCPKG_TARGET_ARCHITECTURE}")
set(GETARCH_BINARY_DIR "${CURRENT_HOST_INSTALLED_DIR}/manual-tools/${PORT}/${SYSTEM_KEY}")
if(EXISTS "${GETARCH_BINARY_DIR}")
    message(STATUS "OpenBLAS cross build, but may use ${PORT}:${HOST_TRIPLET} getarch")
    list(APPEND OPTIONS "-DGETARCH_BINARY_DIR=${GETARCH_BINARY_DIR}")
elseif(VCPKG_CROSSCOMPILING)
    message(STATUS "OpenBLAS cross build, may not be able to use getarch")
else()
    message(STATUS "OpenBLAS native build")
endif()

if(VCPKG_TARGET_IS_EMSCRIPTEN)
    # Only the riscv64 kernel with riscv64_generic target is supported.
    # Cf. https://github.com/OpenMathLib/OpenBLAS/issues/3640#issuecomment-1144029630 et al.
    list(APPEND OPTIONS
        -DEMSCRIPTEN_SYSTEM_PROCESSOR=riscv64
        -DTARGET=RISCV64_GENERIC
    )
endif()

# OVERLAY MODIFICATION -- pin the x86-64 kernel baseline.
#
# On a native build OpenBLAS runs `getarch`, which probes the CPU of whatever
# machine happens to be doing the build, and writes the result into config.h as
# HAVE_AVX512VL / HAVE_AVX512BF16 / etc. Two problems follow from that on shared
# CI runners:
#
#   1. Build breakage. kernel/simd/intrin.h includes intrin_avx512.h purely on
#      `#if defined(HAVE_AVX512VL) || defined(HAVE_AVX512BF16)`, but no matching
#      -mavx512* flag is added for the generic kernels. GCC declares every
#      _mm512_* intrinsic as target("avx512f") + always_inline, and inlining one
#      into a caller that lacks the target option is a hard error:
#        error: inlining failed in call to 'always_inline'
#               '_mm512_castps512_ps128': target specific option mismatch
#      So the build succeeds or fails depending on which runner it lands on.
#
#   2. Non-portable artifacts. With DYNAMIC_ARCH off, the kernels are compiled
#      for the build machine's CPU. A wheel built on an AVX-512 runner can issue
#      AVX-512 on a user's older machine and die with SIGILL. Nothing fails at
#      build time when the flags do happen to line up, so this ships silently.
#
# Forcing TARGET makes getarch run with -DFORCE_<TARGET> instead of probing, so
# config.h is identical on every runner. PRESCOTT is OpenBLAS's conventional
# x86-64 baseline and only sets the floor for the common/driver code.
# DYNAMIC_ARCH then builds every kernel variant (Haswell, SkylakeX, Zen, ...)
# with its own correct flags and dispatches on the *user's* CPU at runtime, so
# pinning the baseline costs no kernel performance.
#
# DYNAMIC_ARCH is requested through the port feature (see vcpkg.json in the
# repo root). It is declared "supports": "!windows | mingw", so it cannot be
# enabled under MSVC -- OpenBLAS's runtime-dispatch kernels rely on GCC-style
# assembly that the MSVC build does not handle. The two platforms therefore get
# different treatment:
#
#   Linux  -- pin the baseline to PRESCOTT and let DYNAMIC_ARCH build every
#             kernel variant, dispatching on the user's CPU at runtime. The
#             pinned baseline only floors the common/driver code, so no kernel
#             performance is lost.
#
#   Windows -- runtime dispatch is unavailable, so the only way to stop shipping
#             a binary tuned to a random runner is to fix the baseline outright.
#             NEHALEM (SSE4.2, 2008+) is chosen for maximum portability. The
#             performance give-up is small in this project's workload because
#             COLMAP and Ceres do most vectorised linear algebra through Eigen,
#             whose own SIMD selection is independent of OpenBLAS's TARGET;
#             OpenBLAS here mainly backs LAPACK for SuiteSparse/Ceres. Raise
#             this to HASWELL (AVX2, 2013+) if the AVX2 floor is acceptable for
#             your users and you want faster dense kernels.
if(VCPKG_TARGET_ARCHITECTURE STREQUAL "x64")
    if(VCPKG_TARGET_IS_WINDOWS)
        list(APPEND OPTIONS -DTARGET=NEHALEM)
        message(STATUS "OpenBLAS: pinned TARGET=NEHALEM (fixed portable baseline; DYNAMIC_ARCH unavailable on MSVC)")
    else()
        list(APPEND OPTIONS -DTARGET=PRESCOTT)
        message(STATUS "OpenBLAS: pinned TARGET=PRESCOTT baseline (runtime dispatch via DYNAMIC_ARCH)")
    endif()
endif()

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        ${OPTIONS}
        "-DCMAKE_PROJECT_INCLUDE=${CURRENT_PORT_DIR}/cmake-project-include.cmake"
        -DBUILD_TESTING=OFF
        -DBUILD_WITHOUT_LAPACK=ON
        -DNOFORTRAN=ON
    MAYBE_UNUSED_VARIABLES
        GETARCH_BINARY_DIR
)

vcpkg_cmake_install()
vcpkg_copy_pdbs()
vcpkg_cmake_config_fixup(CONFIG_PATH lib/cmake/OpenBLAS)
vcpkg_fixup_pkgconfig()

# Required from native builds, optional from cross builds.
if(NOT VCPKG_CROSSCOMPILING OR EXISTS "${CURRENT_PACKAGES_DIR}/bin/getarch${VCPKG_TARGET_EXECUTABLE_SUFFIX}")
    vcpkg_copy_tools(
        TOOL_NAMES getarch getarch_2nd 
        DESTINATION "${CURRENT_PACKAGES_DIR}/manual-tools/${PORT}/${SYSTEM_KEY}"
        AUTO_CLEAN
    )
endif()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include" "${CURRENT_PACKAGES_DIR}/debug/share")

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
