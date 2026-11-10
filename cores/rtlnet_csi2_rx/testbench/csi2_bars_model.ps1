<#
-------------------------------------------------------------------------------
File: csi2_bars_model.ps1
Purpose: build the host C model of the rtlnet_csi2_rx color bars (csi2_bars_model.c) with the host gcc from
  rtlnet_tools.ps1 and run it. Without -SelfTest it prints the MODEL lines (frame size and CRC-32 per video mode) and
  exits 0; with -SelfTest it runs the CRC engine check (crc32("123456789") = 0xCBF43926) and exits 0 only on PASS.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File csi2_bars_model.ps1 [-SelfTest] [-Dump <file> -Mode <720p30|1080p30>]
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [switch]$SelfTest,
    [string]$Dump = '',
    [string]$Mode = '720p30'
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Cc = Resolve-RtlnetHostCc
$env:PATH = "$(Split-Path -Parent $Cc);$env:PATH"
$exe = Join-Path (Get-RtlnetToolDir 'csi2_bars') 'csi2_bars_model.exe'
& $Cc -std=c11 -Wall -Wextra -Werror -pedantic -O2 "$PSScriptRoot/csi2_bars_model.c" -o $exe
if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_BARS_MODEL: FAIL build'; exit 1 }
if ($SelfTest) {
    $out = & $exe --selftest
    $out | Write-Output
    if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_BARS_MODEL: FAIL self test'; exit 1 }
    Write-Output 'CSI2_BARS_MODEL: PASS'
    exit 0
}
if ($Dump) {
    & $exe --dump $Dump $Mode
    exit $LASTEXITCODE
}
& $exe | Write-Output
exit $LASTEXITCODE
