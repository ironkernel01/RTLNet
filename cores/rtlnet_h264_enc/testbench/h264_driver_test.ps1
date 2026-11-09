<#
-------------------------------------------------------------------------------
File: h264_driver_test.ps1
Purpose: build and run the host unit test of the rtlnet_h264_enc driver (test_rtlnet_h264_enc_driver.c) with the
  host gcc from rtlnet_tools.ps1; prints its DRIVER TEST line and exits 0 on PASS.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_driver_test.ps1
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Cc = Resolve-RtlnetHostCc
$env:PATH = "$(Split-Path -Parent $Cc);$env:PATH"
$exe = Join-Path (Get-RtlnetToolDir 'h264_enc') 'test_rtlnet_h264_enc_driver.exe'
& $Cc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST "-I$Repo/cores/rtlnet_common/driver" "-I$Repo/cores/rtlnet_h264_enc/driver" `
    "$Repo/cores/rtlnet_h264_enc/driver/rtlnet_h264_enc.c" "$Repo/cores/rtlnet_h264_enc/testbench/test_rtlnet_h264_enc_driver.c" -o $exe
if ($LASTEXITCODE -ne 0) { Write-Output 'DRIVER TEST FAIL: rtlnet_h264_enc build'; exit 1 }
$out = & $exe
$out | Select-Object -Last 1 | Write-Output
if ($LASTEXITCODE -ne 0) { exit 1 }
exit 0
