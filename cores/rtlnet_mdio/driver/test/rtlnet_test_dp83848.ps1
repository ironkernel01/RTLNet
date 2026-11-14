<#
File: rtlnet_test_dp83848.ps1
Purpose: build and run the IronKernel RTLNet DP83848 host unit test and negative control.
Language: PowerShell. Clocks: none. Source-available.
Revision: 11-14-2026
  * 11-14-2026: add warning-free C11 host regression.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../../scripts/rtlnet_tools.ps1')
$cc = Resolve-RtlnetHostCc
$env:PATH = (Split-Path -Parent $cc) + ';' + $env:PATH
$build = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force $build | Out-Null
$exe = Join-Path $build 'rtlnet_test_dp83848.exe'
& $cc -std=c11 -Wall -Wextra -Werror -pedantic -O2 "-I$PSScriptRoot/.." "-I$PSScriptRoot/../../../rtlnet_common/driver" `
    "$PSScriptRoot/test_rtlnet_phy_dp83848.c" "$PSScriptRoot/../rtlnet_phy_dp83848.c" -o $exe
if ($LASTEXITCODE -ne 0) { Write-Output 'RTLNET_HOSTTEST: FAIL rtlnet_phy_dp83848 build'; exit 1 }
$out = & $exe
$rc = $LASTEXITCODE
$out | Write-Output
if ($rc -ne 0 -or -not ($out -match '^TEST PASS: rtlnet_phy_dp83848 checks=\d+$')) { exit 1 }
$neg = & $exe --inject-failure
$rc = $LASTEXITCODE
$line = $neg | Where-Object { $_ -match '^TEST FAIL: rtlnet_phy_dp83848 ' }
if ($rc -eq 0 -or -not $line) { Write-Output 'RTLNET_HOSTTEST: FAIL rtlnet_phy_dp83848 negative control'; exit 1 }
Write-Output "negative control: $line"
Write-Output 'RTLNET_HOSTTEST: PASS rtlnet_phy_dp83848 (including negative control)'
