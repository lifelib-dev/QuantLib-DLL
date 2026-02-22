# QuantLib-DLL

Pre-built [QuantLib](https://github.com/lballabio/QuantLib) as a Windows x64 DLL.

Upstream QuantLib blocks DLL builds on MSVC. This project patches the source to enable shared library builds and publishes pre-built binaries as GitHub Release assets.

## Download

Go to [Releases](https://github.com/lifelib-dev/QuantLib-DLL/releases) and download the zip for your QuantLib version.

Extract to a directory of your choice (e.g. `C:\quantlib-deps`):

```powershell
Expand-Archive QuantLib-1.41-x64-dll.zip -DestinationPath C:\quantlib-deps
```

This gives you:

```
C:\quantlib-deps\
  QuantLib-1.41\
    bin\QuantLib-x64-mt.dll       # Runtime DLL
    lib\QuantLib-x64-mt.lib       # Import library for linking
    include\ql\...                # QuantLib headers (patched for DLL)
  boost_1_87_0\
    boost\...                     # Boost headers
```

## Build locally

Requirements: Visual Studio 2022 (C++ workload), CMake, 7-Zip.

```powershell
.\scripts\Build-QuantLibDLL.ps1 -PackageZip
```

With custom versions and install location:

```powershell
.\scripts\Build-QuantLibDLL.ps1 `
    -QuantLibVersion 1.41 `
    -BoostVersion 1.87.0 `
    -InstallDir C:\Users\me\quantlib-deps\QuantLib-1.41 `
    -PackageZip
```

Include the QuantLib test suite:

```powershell
.\scripts\Build-QuantLibDLL.ps1 -BuildTests -PackageZip
```

## Patches applied

Five patches are applied to the QuantLib source to enable DLL builds:

| File | Patch |
|------|-------|
| `cmake/Platform.cmake` | Remove `FATAL_ERROR` that blocks DLL builds on MSVC |
| `ql/CMakeLists.txt` | Add `RUNTIME DESTINATION` so `cmake --install` copies the DLL |
| `ql/qldefines.hpp.cfg` | Inject `QL_EXPORT` / `QL_IMPORT_ONLY` macros for `dllexport`/`dllimport` |
| `ql/math/distributions/normaldistribution.hpp` | Add `QL_EXPORT` to `InverseCumulativeNormal` and `MoroInverseCumulativeNormal` |
| `ql/cashflows/lineartsrpricer.hpp` | Add `QL_EXPORT` to `defaultLowerBound` and `defaultUpperBound` static const members |

The last three patches are needed because `CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS` does not export private static const class data members. Without these patches, consumers get unresolved symbol errors at link time.

## Build details

- Visual Studio 2022 (MSVC)
- CMake with `BUILD_SHARED_LIBS=ON` and `CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON`
- MSVC DLL CRT runtime (`/MD`)
- Boost headers only (no compiled Boost libraries needed)

## License

This repository (build scripts and CI configuration) is licensed under the BSD 3-Clause License. QuantLib itself is licensed under the [QuantLib License](https://github.com/lballabio/QuantLib/blob/master/LICENSE.TXT) (BSD-modified).
