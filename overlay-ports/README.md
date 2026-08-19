# vcpkg overlay ports

The maintained wheels use local `suitesparse-cholmod` and `suitesparse-spqr`
ports to work around vcpkg issue
[#44797](https://github.com/microsoft/vcpkg/issues/44797). The patches set the
CUDA architecture list explicitly (`75;80;86;89;90`, plus `120` when supported)
so the CUDA-enabled SuiteSparse build is reproducible.

The local `openblas` port pins the OpenBLAS kernel baseline so builds stop
depending on whichever CPU the CI runner happens to have. Without the pin,
OpenBLAS's `getarch` probes the build host and can emit AVX-512 defines with no
matching compiler flags, which intermittently breaks `vcpkg install` and can
ship non-portable binaries. The port forces `TARGET=PRESCOTT` with
`DYNAMIC_ARCH` runtime dispatch on Linux (requested as `openblas[dynamic-arch]`
in the root `vcpkg.json`) and `TARGET=NEHALEM` on Windows, where dispatch is
unavailable under MSVC.

The local `gmp` port exists only to fix a dead download. On Windows the
pinned vcpkg baseline's gmp port fetches `autoconf2.71-2.71-3` directly from
the MSYS2 mirrors, but MSYS2 rolled that package to `-4` and deleted the old
build, so every mirror now returns 404 and `gmp:x64-windows` fails to
configure. This port is the baseline's gmp with upstream's fix
([vcpkg#53437](https://github.com/microsoft/vcpkg/pull/53437)) applied: the
`-4` URL and its SHA512. Drop it once the pinned vcpkg baseline moves past
2026-08-15.

The top-level CMake project passes this directory through
`VCPKG_OVERLAY_PORTS`. Keep only overrides required by the two maintained wheel
builds, and remove an override once the pinned vcpkg baseline contains the fix.
