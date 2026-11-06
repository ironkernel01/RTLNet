<#
-------------------------------------------------------------------------------
File: build_test.ps1
Purpose: build and run the rtlnet_classifier driver host unit test with the
  host gcc, run its negative control, and compile the driver with the
  MicroBlaze gcc.
Overview:
  * Host build: gcc -std=c11 -Wall -Wextra -Werror -pedantic -O2
    -DRTLNET_HOST_TEST, output in build/ next to this script.
  * PASS requires exit code 0 and the anchored line
    `TEST PASS: rtlnet_classifier_host checks=<n>`; the --inject-failure run
    must print `TEST FAIL: rtlnet_classifier_host`.
  * Target build: mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra
    -Werror -O2 -c rtlnet_classifier.c (skipped with -NoTarget).
  * Prints one summary line `RTLNET_HOSTTEST: PASS|FAIL ...`; exit 0 on PASS.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cores/rtlnet_classifier/driver/test/build_test.ps1 [-NoTarget]
Revision: 10-22-2026
  * 10-22-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [switch]$NoTarget,
    [string]$MbGcc = ''
)
if (-not $MbGcc) { . (Join-Path $PSScriptRoot '..\..\..\..\scripts\rtlnet_tools.ps1'); $MbGcc = (Resolve-RtlnetXilinx).MbBin + '/mb-gcc.exe' }
$ErrorActionPreference = 'Stop'

$Here  = $PSScriptRoot
$Drv   = (Resolve-Path (Join-Path $Here '..')).Path
$Mmio  = (Resolve-Path (Join-Path $Here '../../../rtlnet_common/driver')).Path
$Build = Join-Path $Here 'build'
$Exe   = Join-Path $Build 'test_rtlnet_classifier_host.exe'
New-Item -ItemType Directory -Force -Path $Build | Out-Null

function Fail([string]$why) { Write-Output "RTLNET_HOSTTEST: FAIL $why"; exit 1 }

$inc  = @("-I$Drv", "-I$Mmio")
$srcs = @((Join-Path $Here 'test_rtlnet_classifier_host.c'), (Join-Path $Drv 'rtlnet_classifier.c'))

& gcc -std=c11 -Wall -Wextra -Werror -pedantic -O2 -DRTLNET_HOST_TEST @inc @srcs -o $Exe
if ($LASTEXITCODE -ne 0) { Fail 'host build' }

$out = & $Exe
$rc = $LASTEXITCODE
$out | ForEach-Object { Write-Output $_ }
$pass = $out | Where-Object { $_ -match '^TEST PASS: rtlnet_classifier_host checks=\d+' }
if ($rc -ne 0 -or -not $pass) { Fail "host test (exit $rc)" }

$neg = & $Exe --inject-failure
$negLine = $neg | Where-Object { $_ -match '^TEST FAIL: rtlnet_classifier_host' }
if (-not $negLine) { Fail 'negative control did not report TEST FAIL' }
Write-Output "negative control: $negLine"

if (-not $NoTarget) {
    $obj = Join-Path $Build 'rtlnet_classifier.mb.o'
    # '-mcpu=v11.0' is quoted: Windows PowerShell splits a bare argument at the '.'.
    & $MbGcc -mlittle-endian '-mcpu=v11.0' -std=c11 -Wall -Wextra -Werror -O2 @inc -c (Join-Path $Drv 'rtlnet_classifier.c') -o $obj
    if ($LASTEXITCODE -ne 0) { Fail 'mb-gcc rtlnet_classifier.c' }
    Write-Output 'mb-gcc: rtlnet_classifier.c ok'
}
Write-Output ("RTLNET_HOSTTEST: PASS " + ($pass | Select-Object -First 1))
exit 0
