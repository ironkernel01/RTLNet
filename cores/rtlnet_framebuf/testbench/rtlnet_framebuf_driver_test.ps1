<#
-------------------------------------------------------------------------------
File: rtlnet_framebuf_driver_test.ps1
Purpose: build and run the host unit test of the rtlnet_framebuf driver (test_rtlnet_framebuf_driver.c) with the host gcc from
  rtlnet_tools.ps1; prints its DRIVER TEST line and exits 0 on PASS.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File rtlnet_framebuf_driver_test.ps1
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Cc = Resolve-RtlnetHostCc
$env:PATH = "$(Split-Path -Parent $Cc);$env:PATH"
$exe = Join-Path (Get-RtlnetToolDir 'rtlnet_framebuf') 'test_rtlnet_framebuf_driver.exe'
& $Cc -std=c11 -Wall -Wextra -Werror -pedantic -DRTLNET_HOST_TEST "-I$Repo/cores/rtlnet_common/driver" "-I$Repo/cores/rtlnet_framebuf/driver" `
    "$Repo/cores/rtlnet_framebuf/driver/rtlnet_framebuf.c" "$Repo/cores/rtlnet_framebuf/testbench/test_rtlnet_framebuf_driver.c" -o $exe
if ($LASTEXITCODE -ne 0) { Write-Output 'DRIVER TEST FAIL: rtlnet_framebuf build'; exit 1 }
$out = & $exe
$out | Select-Object -Last 1 | Write-Output
if ($LASTEXITCODE -ne 0) { exit 1 }
exit 0
