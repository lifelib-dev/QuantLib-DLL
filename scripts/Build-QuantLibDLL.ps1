<#
.SYNOPSIS
    Build QuantLib as a shared library (DLL) on Windows with MSVC.

.DESCRIPTION
    Downloads QuantLib source and Boost headers, patches QuantLib to enable
    DLL builds on MSVC, builds with CMake, and optionally packages the output
    as a zip for distribution.

    Upstream QuantLib blocks DLL builds on MSVC with a FATAL_ERROR. This script
    applies five patches to enable DLL builds:
      1. cmake/Platform.cmake      - Remove FATAL_ERROR blocking DLL builds
      2. ql/CMakeLists.txt          - Add RUNTIME DESTINATION for DLL install
      3. ql/qldefines.hpp.cfg       - Inject QL_EXPORT/QL_IMPORT_ONLY macros
      4. normaldistribution.hpp     - Annotate classes with QL_EXPORT
      5. lineartsrpricer.hpp        - Annotate static const members with QL_EXPORT

.PARAMETER QuantLibVersion
    QuantLib version to build (default: 1.41).

.PARAMETER BoostVersion
    Boost version for headers (default: 1.87.0).

.PARAMETER InstallDir
    Where to install QuantLib (cmake --install prefix).
    Default: install/ in the repository root.

.PARAMETER TempDir
    Working directory for source downloads and build artifacts.
    Default: build/ in the repository root so you can inspect patched sources.

.PARAMETER Jobs
    Number of parallel build jobs. 0 = auto-detect (default).

.PARAMETER BuildTests
    Also build the QuantLib test suite.

.PARAMETER PackageZip
    Create a distributable zip containing QuantLib DLL + headers + Boost headers.

.PARAMETER ZipOutputDir
    Directory where the zip file is written (default: current directory).

.EXAMPLE
    .\Build-QuantLibDLL.ps1 -PackageZip

.EXAMPLE
    .\Build-QuantLibDLL.ps1 -QuantLibVersion 1.41 -BoostVersion 1.87.0 -BuildTests -PackageZip
#>

[CmdletBinding()]
param(
    [string]$QuantLibVersion = "1.41",
    [string]$BoostVersion    = "1.87.0",
    [string]$InstallDir      = (Join-Path (Split-Path $PSScriptRoot) "install"),
    [string]$TempDir         = (Join-Path (Split-Path $PSScriptRoot) "build"),
    [int]$Jobs               = 0,
    [switch]$BuildTests,
    [switch]$PackageZip,
    [string]$ZipOutputDir    = "."
)

$ErrorActionPreference = "Stop"

$BoostVersionU = $BoostVersion -replace '\.', '_'
if ($Jobs -eq 0) {
    $Jobs = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
}

New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# ==========================================================================
# 1. Download and extract Boost headers
# ==========================================================================
Write-Host "==> Downloading Boost $BoostVersion (7z archive)"
$BoostUrl = "https://archives.boost.io/release/$BoostVersion/source/boost_${BoostVersionU}.7z"
$Boost7z  = "$TempDir\boost.7z"
if (-not (Test-Path "$TempDir\boost_$BoostVersionU\boost")) {
    Invoke-WebRequest -Uri $BoostUrl -OutFile $Boost7z -UseBasicParsing
    Write-Host "==> Extracting Boost headers to $TempDir"
    7z x $Boost7z -o"$TempDir" -y | Select-String -Pattern "^(Extracting|Everything)" | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "7z extraction failed with exit code $LASTEXITCODE" }
} else {
    Write-Host "==> Boost headers already present, skipping download"
}
$BoostIncludeDir = "$TempDir\boost_$BoostVersionU"
Write-Host "==> Boost headers at $BoostIncludeDir"

# ==========================================================================
# 2. Download and extract QuantLib source
# ==========================================================================
$QLSrcDir = "$TempDir\QuantLib-$QuantLibVersion"
if (-not (Test-Path "$QLSrcDir\CMakeLists.txt")) {
    Write-Host "==> Downloading QuantLib $QuantLibVersion source"
    $QLUrl   = "https://github.com/lballabio/QuantLib/releases/download/v${QuantLibVersion}/QuantLib-${QuantLibVersion}.tar.gz"
    $QLTarGz = "$TempDir\QuantLib.tar.gz"
    Invoke-WebRequest -Uri $QLUrl -OutFile $QLTarGz -UseBasicParsing
    Write-Host "==> Extracting QuantLib source"
    tar xzf $QLTarGz -C $TempDir
    if ($LASTEXITCODE -ne 0) { throw "tar extraction failed with exit code $LASTEXITCODE" }
} else {
    Write-Host "==> QuantLib source already present, skipping download"
}

# ==========================================================================
# 3. Patch QuantLib for DLL builds
# ==========================================================================

# --- 3a. cmake/Platform.cmake: remove FATAL_ERROR blocking DLL builds ---
Write-Host "==> Patching cmake/Platform.cmake to enable DLL builds"
$PlatformCmake = "$QLSrcDir\cmake\Platform.cmake"
$original = Get-Content $PlatformCmake -Raw
$patched = $original -replace `
    'message\(FATAL_ERROR\s*\r?\n\s*"Shared library \(DLL\) builds for QuantLib on MSVC are not supported"\)', `
    '# Patched: DLL build enabled (FATAL_ERROR removed by QuantLib-DLL)'
if ($patched -eq $original) {
    Write-Warning "Platform.cmake patch pattern did not match - file may have changed or already patched"
    Select-String -Path $PlatformCmake -Pattern "FATAL_ERROR|BUILD_SHARED|EXPORT_ALL|Patched" | Write-Host
}
[System.IO.File]::WriteAllText($PlatformCmake, $patched)

# --- 3b. ql/CMakeLists.txt: add RUNTIME DESTINATION for DLL install ---
Write-Host "==> Patching ql/CMakeLists.txt to add RUNTIME DESTINATION"
$qlCmake = "$QLSrcDir\ql\CMakeLists.txt"
$qlContent = Get-Content $qlCmake -Raw
$searchStr = 'LIBRARY DESTINATION ${QL_INSTALL_LIBDIR})'
$replaceStr = 'LIBRARY DESTINATION ${QL_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${QL_INSTALL_BINDIR})'
if ($qlContent.Contains($searchStr)) {
    $qlContent = $qlContent.Replace($searchStr, $replaceStr)
    [System.IO.File]::WriteAllText($qlCmake, $qlContent)
    Write-Host "==> Patched: added RUNTIME DESTINATION"
} else {
    Write-Warning "ql/CMakeLists.txt install() patch target not found (may already be patched)"
}

# --- 3c. qldefines.hpp.cfg: inject QL_EXPORT / QL_IMPORT_ONLY macros ---
Write-Host "==> Patching qldefines.hpp.cfg with DLL export macros"
$qlDefinesCfg = "$QLSrcDir\ql\qldefines.hpp.cfg"
$defContent = Get-Content $qlDefinesCfg -Raw
$exportMacro = @'

// DLL export/import macros for classes with static data members.
// QL_EXPORT: dllexport when building QuantLib, dllimport when consuming.
//   Use on classes whose static const members are NOT exported by
//   CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS (e.g. private static const).
// QL_IMPORT_ONLY: empty when building QuantLib, dllimport when consuming.
//   Use on classes whose members ARE already exported via .def file;
//   class-level dllexport would conflict (C2487).
#if defined(QL_COMPILATION) && defined(_MSC_VER)
#  define QL_EXPORT __declspec(dllexport)
#  define QL_IMPORT_ONLY
#elif defined(_MSC_VER)
#  define QL_EXPORT __declspec(dllimport)
#  define QL_IMPORT_ONLY __declspec(dllimport)
#else
#  define QL_EXPORT
#  define QL_IMPORT_ONLY
#endif
'@
if (-not $defContent.Contains('QL_EXPORT')) {
    $lastEndif = $defContent.LastIndexOf('#endif')
    if ($lastEndif -ge 0) {
        $before = $defContent.Substring(0, $lastEndif)
        $after  = $defContent.Substring($lastEndif)
        $defContent = $before + $exportMacro + "`n`n" + $after
    }
    [System.IO.File]::WriteAllText($qlDefinesCfg, $defContent)
    Write-Host "==> Added QL_EXPORT macro to qldefines.hpp.cfg"
} else {
    Write-Host "==> qldefines.hpp.cfg already contains QL_EXPORT, skipping"
}

# --- 3d. normaldistribution.hpp: annotate classes with QL_EXPORT ---
Write-Host "==> Patching normaldistribution.hpp with QL_EXPORT"
$normalDistHeader = "$QLSrcDir\ql\math\distributions\normaldistribution.hpp"
$ndContent = Get-Content $normalDistHeader -Raw
$ndContent = $ndContent.Replace(
    'class InverseCumulativeNormal {',
    'class QL_EXPORT InverseCumulativeNormal {')
$ndContent = $ndContent.Replace(
    'class MoroInverseCumulativeNormal {',
    'class QL_EXPORT MoroInverseCumulativeNormal {')
[System.IO.File]::WriteAllText($normalDistHeader, $ndContent)

# --- 3e. lineartsrpricer.hpp: annotate static const members with QL_EXPORT ---
Write-Host "==> Patching lineartsrpricer.hpp: QL_EXPORT on static const members"
$linearTsrHeader = "$QLSrcDir\ql\cashflows\lineartsrpricer.hpp"
$ltContent = Get-Content $linearTsrHeader -Raw
$ltContent = $ltContent -replace `
    'static const Real defaultLowerBound,\s+defaultUpperBound;', `
    'QL_EXPORT static const Real defaultLowerBound; QL_EXPORT static const Real defaultUpperBound;'
[System.IO.File]::WriteAllText($linearTsrHeader, $ltContent)

# ==========================================================================
# 4. CMake configure, build, and install
# ==========================================================================
$QLBuildDir = "$QLSrcDir\build"

Write-Host "==> Configuring QuantLib (shared library build)"
$cmakeArgs = @(
    "-S", $QLSrcDir
    "-B", $QLBuildDir
    "-G", "Visual Studio 17 2022"
    "-A", "x64"
    "-DCMAKE_INSTALL_PREFIX=$InstallDir"
    "-DBUILD_SHARED_LIBS=ON"
    "-DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON"
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded$<$<CONFIG:Debug>:Debug>DLL'
    "-DBoost_INCLUDE_DIR=$BoostIncludeDir"
    "-DQL_BUILD_BENCHMARK=OFF"
    "-DQL_BUILD_EXAMPLES=OFF"
    "-DQL_BUILD_TEST_SUITE=$( if ($BuildTests) { 'ON' } else { 'OFF' } )"
    "-Wno-dev"
)
Write-Host "  cmake $($cmakeArgs -join ' ')"
cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE" }

# Verify the generated qldefines.hpp contains QL_EXPORT
$generatedDefines = "${QLBuildDir}\ql\qldefines.hpp"
if (Test-Path $generatedDefines) {
    Write-Host "==> Verifying QL_EXPORT in generated qldefines.hpp:"
    Select-String -Path $generatedDefines -Pattern "QL_EXPORT" | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Warning "Generated qldefines.hpp not found at ${generatedDefines}"
}

Write-Host "==> Building QuantLib with $Jobs parallel jobs"
cmake --build $QLBuildDir --config Release --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw "CMake build failed with exit code $LASTEXITCODE" }

Write-Host "==> Installing QuantLib to $InstallDir"
cmake --install $QLBuildDir --config Release
if ($LASTEXITCODE -ne 0) { throw "CMake install failed with exit code $LASTEXITCODE" }

# ==========================================================================
# 5. Verify
# ==========================================================================
Write-Host "==> Checking for QuantLib DLL"
$DllPath = Get-ChildItem -Recurse $InstallDir -Filter "QuantLib*.dll" | Select-Object -First 1
if (-not $DllPath) {
    Write-Error "QuantLib DLL not found under $InstallDir!"
    exit 1
}
Write-Host "==> Found DLL: $($DllPath.FullName)"

Write-Host "==> Contents of $InstallDir\lib"
Get-ChildItem "$InstallDir\lib" | Format-Table Name, Length

Write-Host "==> Contents of $InstallDir\bin"
if (Test-Path "$InstallDir\bin") {
    Get-ChildItem "$InstallDir\bin" | Format-Table Name, Length
}

# ==========================================================================
# 6. Package zip (optional)
# ==========================================================================
if ($PackageZip) {
    Write-Host "==> Packaging distribution zip"
    $ZipName    = "QuantLib-${QuantLibVersion}-x64-dll.zip"
    $StagingDir = "$TempDir\staging"

    # Clean staging area
    if (Test-Path $StagingDir) { Remove-Item -Recurse -Force $StagingDir }
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

    # Copy QuantLib install tree
    Copy-Item -Recurse "$InstallDir" "$StagingDir\QuantLib-$QuantLibVersion"

    # Copy test suite executable if built
    if ($BuildTests) {
        $TestExe = Get-ChildItem -Recurse "$QLBuildDir\test-suite" -Filter "ql_test_suite.exe" |
                   Where-Object { $_.Directory.Name -eq "Release" } | Select-Object -First 1
        if ($TestExe) {
            Copy-Item $TestExe.FullName "$StagingDir\QuantLib-$QuantLibVersion\bin\"
            Write-Host "==> Included test suite: $($TestExe.FullName)"
        } else {
            Write-Warning "Test suite executable not found"
        }
    }

    # Copy Boost headers
    Copy-Item -Recurse "$BoostIncludeDir" "$StagingDir\boost_$BoostVersionU"

    # Copy license files
    $ScriptRoot = Split-Path -Parent $PSScriptRoot   # repo root
    Copy-Item "$ScriptRoot\LICENSE_QUANTLIB.txt" "$StagingDir\"
    Copy-Item "$ScriptRoot\LICENSE_BOOST.txt" "$StagingDir\"

    # Create zip
    New-Item -ItemType Directory -Path $ZipOutputDir -Force | Out-Null
    $ZipPath = Join-Path (Resolve-Path $ZipOutputDir) $ZipName
    if (Test-Path $ZipPath) { Remove-Item $ZipPath }
    Compress-Archive -Path "$StagingDir\*" -DestinationPath $ZipPath
    $ZipSize = [math]::Round((Get-Item $ZipPath).Length / 1MB, 1)
    Write-Host "==> Created $ZipPath ($ZipSize MB)"
}

Write-Host "==> QuantLib DLL build completed successfully"
