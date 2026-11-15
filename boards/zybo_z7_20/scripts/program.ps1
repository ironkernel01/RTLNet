<#
-------------------------------------------------------------------------------
File: program.ps1
Purpose: load the Zybo Z7-20 camera and H.264 design over JTAG (volatile: nothing is written to QSPI or an SD card): bitstream,
  PS initialization from the XSA, ARM application, run.
Overview:
  * Takes the machine-wide board lock (rtlnet_board_lock.ps1) before touching the board; the lock stays until the
    session releases it (scripts/rtlnet_board.ps1 release).
  * Default inputs come from one build tag: boards/zybo_z7_20/build/<Tag>/rtlnet_zybo_z7_20.{bit,xsa} and
    cpu/zynq7_h264/firmware/build/<FwTag>/rtlnet_zybo.elf (FwTag defaults to Tag). ps7_init.tcl is taken from the XSA.
  * xsdb (resolved by rtlnet_tools.ps1) runs program.tcl: refuses unless the chain holds an xc7z020 device and the
    Cortex-A9 targets, then ps7_init, fpga, ps7_post_config, dow, con.
  * Output: the rtlnet_zybo_load: lines of the xsdb log (build/<Tag>/program.log); last line RTLNET_ZYBO_PROGRAM: PASS|FAIL.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/program.ps1 -Tag enc13 [-FwTag enc13] [-Elf <file>]
Revision: 11-15-2026
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_]{1,24}$')][string]$Tag,
      [string]$FwTag = '', [string]$Elf = '')
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
. (Join-Path $Repo 'scripts\rtlnet_board_lock.ps1')
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
Enter-RtlnetBoardLock -Purpose 'zybo program' -ExpectedMinutes 120
if (-not $FwTag) { $FwTag = $Tag }
$Out = Join-Path $Board "build\$Tag"
$Bit = Join-Path $Out 'rtlnet_zybo_z7_20.bit'
$Xsa = Join-Path $Out 'rtlnet_zybo_z7_20.xsa'
if (-not $Elf) { $Elf = Join-Path $Repo "cpu\zynq7_h264\firmware\build\$FwTag\rtlnet_zybo.elf" }
foreach ($f in $Bit, $Xsa, $Elf) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Output "RTLNET_ZYBO_PROGRAM: FAIL missing $f"; exit 2 }
}
# ps7_init.tcl of the XSA that holds the bitstream.
$Init = Join-Path $Out 'ps7_init.tcl'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($Xsa)
try {
    $e = $zip.GetEntry('ps7_init.tcl')
    if (-not $e) { Write-Output 'RTLNET_ZYBO_PROGRAM: FAIL no ps7_init.tcl in the XSA'; exit 2 }
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $Init, $true)
} finally { $zip.Dispose() }
$x = Resolve-RtlnetXilinx
$xsdb = $x.Vitis + '/bin/xsdb.bat'
if (-not (Test-Path -LiteralPath $xsdb)) { $xsdb = $x.Vivado + '/bin/xsdb.bat' }
$log = Join-Path $Out 'program.log'
$fwd = { param($p) ((Resolve-Path -LiteralPath $p).Path -replace '[\\]', '/') }
$out = & $xsdb (Join-Path $PSScriptRoot 'program.tcl') (& $fwd $Bit) (& $fwd $Init) (& $fwd $Elf) 2>&1
$rc = $LASTEXITCODE
# xsdb.bat can return 0 after a Tcl exit with an error: the verdict needs the script's own final PASS line.
if (-not ($out | Where-Object { "$_" -match '^rtlnet_zybo_load: PASS' })) { if ($rc -eq 0) { $rc = 3 } }
[System.IO.File]::WriteAllText($log, (($out | ForEach-Object { "$_" }) -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$out | ForEach-Object { "$_" } | Where-Object { $_ -match 'rtlnet_zybo_load:|^\s*\d+\s+\S|ERROR|Error' } | ForEach-Object { Write-Output $_ }
Write-Output ("RTLNET_ZYBO_PROGRAM: {0} (exit {1})" -f ($(if ($rc -eq 0) { 'PASS' } else { 'FAIL' }), $rc))
exit $rc
