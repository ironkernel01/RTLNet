<#
-------------------------------------------------------------------------------
File: phy_host_test.ps1
Purpose: build and run the host test of the PHY driver selection (phy_host_test.c) with the host C compiler found by
  Resolve-RtlnetHostCc: the positive run and the negative control (--neg). Exit code 0 when both behave.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/firmware/test/phy_host_test.ps1
Revision: 11-14-2026
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Fw   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo = (Resolve-Path (Join-Path $Fw '..\..\..')).Path
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
$cc  = Resolve-RtlnetHostCc
$out = Join-Path $Fw 'build\phy_test.exe'
New-Item -ItemType Directory -Force -Path (Join-Path $Fw 'build') | Out-Null
& $cc -std=c11 -Wall -Wextra -Werror -pedantic -O2 "-I$Fw/src" "-I$Repo/cores/rtlnet_common/driver" "-I$Repo/cores/rtlnet_mdio/driver" `
    -o $out "$Fw/test/phy_host_test.c" "$Fw/src/rtlnet_phy.c" "$Repo/cores/rtlnet_mdio/driver/rtlnet_phy_rtl8211e.c" "$Repo/cores/rtlnet_mdio/driver/rtlnet_phy_dp83848.c"
if ($LASTEXITCODE -ne 0) { Write-Output 'PHY_HOST_TEST: FAIL build'; exit 1 }
$a = & $out
$ra = $LASTEXITCODE
$b = & $out --neg
$rb = $LASTEXITCODE
$a | Select-Object -Last 4 | Write-Output
$b | Select-Object -Last 2 | Write-Output
if ($ra -ne 0 -or $rb -eq 0) { Write-Output 'PHY_HOST_TEST: FAIL (positive run must pass, negative control must fail)'; exit 1 }
Write-Output 'PHY_HOST_TEST: positive run passes, negative control fails as required'
exit 0
