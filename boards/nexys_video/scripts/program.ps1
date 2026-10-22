<#
-------------------------------------------------------------------------------
File: program.ps1
Purpose: program the Nexys Video FPGA over JTAG (volatile, lost at power
  cycle) with the merged bitstream, through the machine-wide Vivado launcher.
Overview:
  * Default bitstream: boards/nexys_video/build/rtlnet_nexys_video.bit (the
    firmware-merged image from merge_elf.ps1); -Bit selects another.
  * Runs program.tcl through scripts/rtlnet_vivado.ps1 (one of the two
    machine-wide Vivado slots); prints the rtlnet_program: lines of the log.
  * Exit code: the Tcl's (0 programmed with DONE high).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1 [-Bit <file>]
Revision: 10-22-2026
  * 10-22-2026: initial version.
-------------------------------------------------------------------------------
#>
param([string]$Bit = '')
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
if (-not $Bit) { $Bit = Join-Path $Board 'build\rtlnet_nexys_video.bit' }
if (-not (Test-Path -LiteralPath $Bit)) { Write-Output "RTLNET_PROGRAM: FAIL missing $Bit"; exit 2 }
$Bit = (Resolve-Path -LiteralPath $Bit).Path -replace '\\', '/'
$log = Join-Path $Board 'build\program.log'
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
& (Join-Path $Repo 'scripts\rtlnet_vivado.ps1') -Tcl (Join-Path $PSScriptRoot 'program.tcl') -Log $log -TclArgs @($Bit) | Out-Null
$rc = $LASTEXITCODE
if (Test-Path -LiteralPath $log) {
    Get-Content -LiteralPath $log | Where-Object { $_ -match '^rtlnet_program:' } | ForEach-Object { Write-Output $_ }
}
Write-Output ("RTLNET_PROGRAM: {0} (exit {1})" -f ($(if ($rc -eq 0) { 'PASS' } else { 'FAIL' }), $rc))
exit $rc
