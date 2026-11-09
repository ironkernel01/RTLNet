<#
-------------------------------------------------------------------------------
File: h264_build_decoders.ps1
Purpose: build the two reference H.264 decoders of the rtlnet_h264_top harness
  with the host gcc/g++ (rtlnet_tools.ps1 resolvers): JM ldecod (JM-19.1) and
  the OpenH264 console decoder h264dec (no assembly, so no nasm).
Overview:
  * The sources are copied from the read-only reference trees into the tool
    directory first (%LOCALAPPDATA%/RTLNet/tools/jm and .../openh264, or
    $env:RTLNET_TOOLS_DIR); nothing is built inside the reference trees.
    Reference roots: $env:RTLNET_JM_SRC (default Z:\IronKernel\refs\jm\JM-19.1)
    and $env:RTLNET_OPENH264_SRC (default Z:\IronKernel\refs\openh264\src).
  * JM: all of source/app/ldecod/*.c and source/lib/lcommon/*.c; the copy of
    win32.h is patched so MinGW uses its own intptr_t ("#if (_MSC_VER < 1400)"
    becomes "#if 0"). Command (in <tooldir>/jm):
      gcc -O2 -w -I src -o bin/ldecod.exe src/*.c -lm -lws2_32
  * OpenH264: codec/common, codec/decoder, codec/api, codec/console/{dec,common}.
    Command (in <tooldir>/openh264/src):
      g++ -O2 -w -DNDEBUG -Icodec/api/wels -Icodec/common/inc -Icodec/decoder/core/inc
          -Icodec/decoder/plus/inc -Icodec/console/common/inc -Icodec/console/dec/inc
          -Icodec/api -o ../bin/h264dec.exe codec/common/src/*.cpp
          codec/decoder/core/src/*.cpp codec/decoder/plus/src/welsDecoderExt.cpp
          codec/console/dec/src/*.cpp codec/console/common/src/read_config.cpp
          -ld3d9 -lole32 -lwinmm
  * -Force rebuilds an existing executable.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_build_decoders.ps1 [-Force]
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
param([switch]$Force)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../scripts/rtlnet_tools.ps1')
$cc  = Resolve-RtlnetHostCc
$cxx = Resolve-RtlnetHostCxx
$ccDir = Split-Path -Parent $cc
$env:PATH = "$ccDir;$env:PATH"

$jmSrc = if ($env:RTLNET_JM_SRC) { $env:RTLNET_JM_SRC } else { 'Z:\IronKernel\refs\jm\JM-19.1' }
$ohSrc = if ($env:RTLNET_OPENH264_SRC) { $env:RTLNET_OPENH264_SRC } else { 'Z:\IronKernel\refs\openh264\src' }

# ----- JM ldecod --------------------------------------------------------------
$jmDir = Get-RtlnetToolDir 'jm'
$jmExe = "$jmDir/bin/ldecod.exe"
if ($Force -or -not (Test-Path -LiteralPath $jmExe)) {
    if (-not (Test-Path -LiteralPath "$jmSrc\source\app\ldecod")) { throw "JM source not found under $jmSrc" }
    if (Test-Path -LiteralPath "$jmDir/src") { Remove-Item -LiteralPath "$jmDir/src" -Recurse -Force }
    New-Item -ItemType Directory -Force -Path "$jmDir/src", "$jmDir/bin" | Out-Null
    Copy-Item -Path "$jmSrc\source\app\ldecod\*.c", "$jmSrc\source\app\ldecod\*.h" -Destination "$jmDir/src"
    Copy-Item -Path "$jmSrc\source\lib\lcommon\*.c", "$jmSrc\source\lib\lcommon\*.h" -Destination "$jmDir/src"
    $w32 = "$jmDir/src/win32.h"
    $txt = [System.IO.File]::ReadAllText($w32)
    $txt = $txt.Replace('#if (_MSC_VER < 1400)', '#if 0')
    [System.IO.File]::WriteAllText($w32, $txt, (New-Object System.Text.UTF8Encoding($false)))
    Push-Location $jmDir
    try {
        & $cc -O2 -w -I src -o bin/ldecod.exe (Get-ChildItem src -Filter *.c | ForEach-Object { "src/$($_.Name)" }) -lm -lws2_32
        if ($LASTEXITCODE -ne 0) { throw "JM build failed" }
    } finally { Pop-Location }
}
Write-Output "ldecod: $jmExe"

# ----- OpenH264 h264dec -------------------------------------------------------
$ohDir = Get-RtlnetToolDir 'openh264'
$ohExe = "$ohDir/bin/h264dec.exe"
if ($Force -or -not (Test-Path -LiteralPath $ohExe)) {
    if (-not (Test-Path -LiteralPath "$ohSrc\codec\decoder")) { throw "OpenH264 source not found under $ohSrc" }
    if (Test-Path -LiteralPath "$ohDir/src") { Remove-Item -LiteralPath "$ohDir/src" -Recurse -Force }
    New-Item -ItemType Directory -Force -Path "$ohDir/src/codec/console/dec", "$ohDir/src/codec/console/common", "$ohDir/bin" | Out-Null
    foreach ($d in 'api', 'common', 'decoder') { Copy-Item -Path "$ohSrc\codec\$d" -Destination "$ohDir/src/codec" -Recurse }
    Copy-Item -Path "$ohSrc\codec\console\dec\inc", "$ohSrc\codec\console\dec\src" -Destination "$ohDir/src/codec/console/dec" -Recurse
    Copy-Item -Path "$ohSrc\codec\console\common\inc", "$ohSrc\codec\console\common\src" -Destination "$ohDir/src/codec/console/common" -Recurse
    Push-Location "$ohDir/src"
    try {
        $srcs = @()
        $srcs += Get-ChildItem codec/common/src -Filter *.cpp | ForEach-Object { "codec/common/src/$($_.Name)" }
        $srcs += Get-ChildItem codec/decoder/core/src -Filter *.cpp | ForEach-Object { "codec/decoder/core/src/$($_.Name)" }
        $srcs += 'codec/decoder/plus/src/welsDecoderExt.cpp'
        $srcs += Get-ChildItem codec/console/dec/src -Filter *.cpp | ForEach-Object { "codec/console/dec/src/$($_.Name)" }
        $srcs += 'codec/console/common/src/read_config.cpp'
        & $cxx -O2 -w -DNDEBUG -Icodec/api/wels -Icodec/common/inc -Icodec/decoder/core/inc -Icodec/decoder/plus/inc `
            -Icodec/console/common/inc -Icodec/console/dec/inc -Icodec/api -o ../bin/h264dec.exe @srcs -ld3d9 -lole32 -lwinmm
        if ($LASTEXITCODE -ne 0) { throw "OpenH264 build failed" }
    } finally { Pop-Location }
}
Write-Output "h264dec: $ohExe"
