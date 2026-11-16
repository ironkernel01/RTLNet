<#
-------------------------------------------------------------------------------
File: program_demo.ps1
Purpose: load the released Zybo Z7-20 camera demo over JTAG from the files of a demo folder (volatile: nothing is written to QSPI or an SD
  card): bitstream, PS initialization, ARM application, run.
Overview:
  * Inputs are the three binaries of the demo folder (default demos/h264_baseline/zybo_z7_20): rtlnet_zybo_z7_20.bit, ps7_init.tcl and
    rtlnet_zybo.elf. No build folder, XSA or source is read. The loader itself is boards/zybo_z7_20/scripts/program.tcl, the same as program.ps1.
  * Takes the machine-wide board lock (rtlnet_board_lock.ps1) before touching the board; the lock stays until the session releases it
    (scripts/rtlnet_board.ps1 release).
  * xsdb (resolved by rtlnet_tools.ps1) refuses unless the chain holds an xc7z020 device and the Cortex-A9 targets, then ps7_init, fpga,
    ps7_post_config, dow, con. ARM core 0 only.
  * Output: the rtlnet_zybo_load: lines of the xsdb log (the whole log goes to %TEMP%\rtlnet_zybo_demo_program.log; the demo folder stays
    unchanged); last line RTLNET_ZYBO_PROGRAM: PASS|FAIL.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/program_demo.ps1 [-Dir demos/h264_baseline/zybo_z7_20]
Revision: 11-16-2026
  * 11-16-2026: initial version.
-------------------------------------------------------------------------------
#>
param([string]$Dir = '')
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
. (Join-Path $Repo 'scripts\rtlnet_board_lock.ps1')
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
if (-not $Dir) { $Dir = Join-Path $Repo 'demos\h264_baseline\zybo_z7_20' }
$Dir = (Resolve-Path -LiteralPath $Dir).Path
$Bit  = Join-Path $Dir 'rtlnet_zybo_z7_20.bit'
$Init = Join-Path $Dir 'ps7_init.tcl'
$Elf  = Join-Path $Dir 'rtlnet_zybo.elf'
foreach ($f in $Bit, $Init, $Elf) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Output "RTLNET_ZYBO_PROGRAM: FAIL missing $f"; exit 2 }
}
Enter-RtlnetBoardLock -Purpose 'zybo demo program' -ExpectedMinutes 60
$x = Resolve-RtlnetXilinx
$xsdb = $x.Vitis + '/bin/xsdb.bat'
if (-not (Test-Path -LiteralPath $xsdb)) { $xsdb = $x.Vivado + '/bin/xsdb.bat' }
$log = Join-Path $env:TEMP 'rtlnet_zybo_demo_program.log'
$fwd = { param($p) ((Resolve-Path -LiteralPath $p).Path -replace '[\\]', '/') }
$out = & $xsdb (Join-Path $PSScriptRoot 'program.tcl') (& $fwd $Bit) (& $fwd $Init) (& $fwd $Elf) 2>&1
$rc = $LASTEXITCODE
# xsdb.bat can return 0 after a Tcl exit with an error: the verdict needs the script's own final PASS line.
if (-not ($out | Where-Object { "$_" -match '^rtlnet_zybo_load: PASS' })) { if ($rc -eq 0) { $rc = 3 } }
[System.IO.File]::WriteAllText($log, (($out | ForEach-Object { "$_" }) -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$out | ForEach-Object { "$_" } | Where-Object { $_ -match 'rtlnet_zybo_load:|^\s*\d+\s+\S|ERROR|Error' } | ForEach-Object { Write-Output $_ }
Write-Output ("RTLNET_ZYBO_PROGRAM: {0} (exit {1})" -f ($(if ($rc -eq 0) { 'PASS' } else { 'FAIL' }), $rc))
exit $rc
