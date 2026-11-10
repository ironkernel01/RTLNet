<#
-------------------------------------------------------------------------------
File: rtlnet_vdma_s2mm_driver_test.ps1
Purpose: build and run the host unit test of the rtlnet_vdma_s2mm driver (test_rtlnet_vdma_s2mm_driver.c) with the host gcc from
  rtlnet_tools.ps1; prints its DRIVER TEST line and exits 0 on PASS.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File rtlnet_vdma_s2mm_driver_test.ps1
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Cc = Resolve-RtlnetHostCc
$env:PATH = "$(Split-Path -Parent $Cc);$env:PATH"
$exe = Join-Path (Get-RtlnetToolDir 'rtlnet_vdma_s2mm') 'test_rtlnet_vdma_s2mm_driver.exe'
& $Cc -std=c11 -Wall -Wextra -Werror -pedantic -DRTLNET_HOST_TEST "-I$Repo/cores/rtlnet_common/driver" "-I$Repo/cores/rtlnet_vdma_s2mm/driver" `
    "$Repo/cores/rtlnet_vdma_s2mm/driver/rtlnet_vdma_s2mm.c" "$Repo/cores/rtlnet_vdma_s2mm/testbench/test_rtlnet_vdma_s2mm_driver.c" -o $exe
if ($LASTEXITCODE -ne 0) { Write-Output 'DRIVER TEST FAIL: rtlnet_vdma_s2mm build'; exit 1 }
$out = & $exe
$out | Select-Object -Last 1 | Write-Output
if ($LASTEXITCODE -ne 0) { exit 1 }
exit 0
