<#
-------------------------------------------------------------------------------
File: txring_host_test.ps1
Purpose: build and run the host test of the console transmit ring (txring_host_test.c) with the host C compiler found by
  Resolve-RtlnetHostCc: the positive run and the negative control (--neg). Exit code 0 when both pass.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/firmware/test/txring_host_test.ps1
Revision: 11-14-2026
  * 11-14-2026: moved to cpu/microblaze_v_ethernet/ (was microblaze/).
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Fw   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo = (Resolve-Path (Join-Path $Fw '..\..\..')).Path
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
$cc  = Resolve-RtlnetHostCc
$out = Join-Path $Fw 'build\txring_test.exe'
New-Item -ItemType Directory -Force -Path (Join-Path $Fw 'build') | Out-Null
& $cc -std=c11 -Wall -Wextra -Werror -pedantic -O2 "-I$Fw/src" -o $out "$Fw/test/txring_host_test.c" "$Fw/src/rtlnet_txring.c"
if ($LASTEXITCODE -ne 0) { Write-Output 'TXRING_TEST: FAIL build'; exit 1 }
$a = & $out
$ra = $LASTEXITCODE
$b = & $out --neg
$rb = $LASTEXITCODE
$a | Select-Object -Last 4 | Write-Output
$b | Select-Object -Last 2 | Write-Output
if ($ra -ne 0 -or $rb -ne 0) { exit 1 }
Write-Output 'TXRING_TEST: both runs pass'
exit 0
