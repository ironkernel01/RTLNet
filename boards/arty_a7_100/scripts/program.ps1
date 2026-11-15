<#
-------------------------------------------------------------------------------
File: program.ps1
Purpose: program the Arty A7-100T FPGA over JTAG (volatile, lost at power cycle; the Quad-SPI flash is never touched) with the
  merged bitstream, through the machine-wide Vivado launcher and the board lock.
Overview:
  * Default bitstream: boards/arty_a7_100/build/<Tag>/rtlnet_arty_a7_100_eth.bit (-Tag, default: the untagged build folder) or
    the file named by -Bit. Use the firmware-merged .bit, not the _hw.bit.
  * Runs boards/nexys_video/scripts/program.tcl (board independent: the device pattern is its second argument) with the
    pattern xc7a100t*: every JTAG target of the hw_server is searched and only a target whose chain holds an xc7a100t is
    programmed, so another board on the same PC (a Nexys Video is an xc7a200t) is never selected and the script fails
    (exit 1) when no Arty is found.
  * Takes the machine-wide board lock (rtlnet_board_lock.ps1) before touching the board; the session releases it with
    scripts/rtlnet_board.ps1 release.
  * Exit code: the Tcl's (0 programmed with DONE high).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/arty_a7_100/scripts/program.ps1 [-Tag <tag>] [-Bit <file>]
Revision: 11-14-2026
  * 11-14-2026: initial version (reuses boards/nexys_video/scripts/program.tcl through its device pattern argument).
-------------------------------------------------------------------------------
#>
param([string]$Tag = '', [string]$Bit = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\..\scripts\rtlnet_board_lock.ps1')
Enter-RtlnetBoardLock -Purpose 'program arty' -ExpectedMinutes 60
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
if (-not $Bit) {
    $dir = Join-Path $Board 'build'
    if ($Tag) { $dir = Join-Path $dir $Tag }
    $Bit = Join-Path $dir 'rtlnet_arty_a7_100_eth.bit'
}
if (-not (Test-Path -LiteralPath $Bit)) { Write-Output "RTLNET_PROGRAM: FAIL missing $Bit"; exit 2 }
$Bit = (Resolve-Path -LiteralPath $Bit).Path.Replace('\', '/')
$log = Join-Path $Board 'build\program.log'
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
& (Join-Path $Repo 'scripts\rtlnet_vivado.ps1') -Tcl (Join-Path $Repo 'boards\nexys_video\scripts\program.tcl') -Log $log `
    -TclArgs @($Bit, 'xc7a100t*') | Out-Null
$rc = $LASTEXITCODE
if (Test-Path -LiteralPath $log) {
    Get-Content -LiteralPath $log | Where-Object { $_ -match '^rtlnet_program:' } | ForEach-Object { Write-Output $_ }
}
Write-Output ("RTLNET_PROGRAM: {0} (exit {1})" -f ($(if ($rc -eq 0) { 'PASS' } else { 'FAIL' }), $rc))
exit $rc
