<#
-------------------------------------------------------------------------------
File: build.ps1
Purpose: one-command build of the RTLNet Nexys Video image: firmware ELF,
  bitstream (Vivado, gated), firmware merged into the block RAM, and
  optionally JTAG programming and the console test.
Overview:
  1. microblaze/firmware/build.ps1 -Demo: CLI table check, firmware.elf,
     host harness and its scripted demo (TEST PASS required).
  2. build_bitstream.tcl through scripts/rtlnet_vivado.ps1 (machine-wide
     Vivado slot); BUILD_ID from git rev-parse --short=8 HEAD and the dirty
     flag from git status, both inside the Tcl. -Network defines
     RTLNET_WITH_NETWORK (needs the network cores' filelists).
  3. merge_elf.ps1: updatemem -> build/rtlnet_nexys_video.bit.
  4. -Program: program.ps1 (JTAG). -Test: cli_test.ps1 on -Port (implies
     -Program).
  * Paths derive from this script's location; outputs in boards/nexys_video/build.
  * Exit code 0 only when every step passed; otherwise the failing step's
    code (the Vivado gate codes are listed in build_bitstream.tcl).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/build.ps1 `
    [-Network] [-SkipFirmware] [-Program] [-Test] [-Port COM4]
Revision: 10-22-2026
  * 10-22-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [switch]$Network,
    [switch]$SkipFirmware,
    [switch]$Program,
    [switch]$Test,
    [string]$Port = 'COM4'
)
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
$Build = Join-Path $Board 'build'
New-Item -ItemType Directory -Force -Path $Build | Out-Null

function Step([string]$name, [scriptblock]$body) {
    Write-Output "=== $name"
    $t0 = Get-Date
    & $body
    $rc = $LASTEXITCODE
    Write-Output ("=== {0}: exit {1} ({2:N0} s)" -f $name, $rc, ((Get-Date) - $t0).TotalSeconds)
    if ($rc -ne 0) { Write-Output "RTLNET_BUILD: FAIL at '$name' (exit $rc)"; exit $rc }
}

if (-not $SkipFirmware) {
    Step 'firmware' { powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'microblaze\firmware\build.ps1') -Demo }
}
$net = $(if ($Network) { '1' } else { '0' })
Step 'bitstream' {
    & (Join-Path $Repo 'scripts\rtlnet_vivado.ps1') -Tcl (Join-Path $PSScriptRoot 'build_bitstream.tcl') `
        -Log (Join-Path $Build 'build_bitstream.log') -TclArgs @('network', $net)
}
Get-Content -LiteralPath (Join-Path $Build 'build_bitstream.log') | Where-Object { $_ -match '^(rtlnet_build|rtlnet_cdc):' } |
    ForEach-Object { Write-Output "  $_" }
Step 'merge' { powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'merge_elf.ps1') }
if ($Program -or $Test) {
    Step 'program' { powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'program.ps1') }
}
if ($Test) {
    Step 'cli_test' { powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'cli_test.ps1') -Port $Port }
}
Write-Output '--- build_info.txt'
Get-Content -LiteralPath (Join-Path $Build 'build_info.txt') | ForEach-Object { Write-Output "  $_" }
Write-Output "RTLNET_BUILD: PASS $(Join-Path $Build 'rtlnet_nexys_video.bit')"
exit 0
