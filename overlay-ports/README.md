# vcpkg overlay ports

The maintained wheels use local `suitesparse-cholmod` and `suitesparse-spqr`
ports to work around vcpkg issue
[#44797](https://github.com/microsoft/vcpkg/issues/44797). The patches set the
CUDA architecture list explicitly (`75;80;86;89;90`, plus `120` when supported)
so the CUDA-enabled SuiteSparse build is reproducible.

The top-level CMake project passes this directory through
`VCPKG_OVERLAY_PORTS`. Keep only overrides required by the two maintained wheel
builds, and remove an override once the pinned vcpkg baseline contains the fix.
