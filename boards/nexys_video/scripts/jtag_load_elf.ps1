<#
-------------------------------------------------------------------------------
File: jtag_load_elf.ps1
Purpose: load an ELF into the MicroBlaze V local memory of the programmed
  Nexys Video over JTAG and run it, then show the console output of the
  firmware boot.
Overview:
  * Finds xsdb through scripts/rtlnet_tools.ps1 (Resolve-RtlnetXilinx .Vitis,
    bin/xsdb.bat; RTLNET_XILINX overrides the install).
  * Opens the console port (115200 8N1) first, runs jtag_load_elf.tcl
    (connect, Hart #0, stop, PC and a0, dow, con), then reads the port for
    -WaitMs and prints it. The boot banner and the CLI prompt are the proof
    that the loaded ELF runs: the line "JTAG_LOAD_ELF: PASS" needs the Tcl
    PASS line and a CLI prompt (rtlnet>) on the port.
  * Needs the FPGA programmed with the MicroBlaze V image (program.ps1).
  * Exit code 0 on PASS, 1 on FAIL.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/jtag_load_elf.ps1 `
    [-Elf <elf>] [-Port COM3] [-Baud 115200] [-WaitMs 4000]
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string]$Elf = '',
    [string]$Port = 'COM3',
    [int]$Baud = 115200,
    [int]$WaitMs = 4000
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
if (-not $Elf) { $Elf = Join-Path $Repo 'microblaze\firmware\build\firmware.elf' }
if (-not (Test-Path -LiteralPath $Elf)) { Write-Output "JTAG_LOAD_ELF: FAIL missing $Elf"; exit 1 }
$Elf = (Resolve-Path -LiteralPath $Elf).Path
$xsdb = Join-Path (Resolve-RtlnetXilinx).Vitis 'bin/xsdb.bat'
if (-not (Test-Path -LiteralPath $xsdb)) { Write-Output "JTAG_LOAD_ELF: FAIL no xsdb at $xsdb"; exit 1 }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
try { $sp.Open() } catch { Write-Output "JTAG_LOAD_ELF: FAIL cannot open ${Port}: $($_.Exception.Message)"; exit 1 }
try {
    [void]$sp.ReadExisting()
    $out = & $xsdb (Join-Path $PSScriptRoot 'jtag_load_elf.tcl') ($Elf -replace '\\', '/') 2>&1 | Out-String
    $out -split "`r?`n" | Where-Object { $_ -match '^rtlnet_jtag:' } | ForEach-Object { Write-Output $_ }
    $tclPass = $out -match '(?m)^rtlnet_jtag: PASS'
    Start-Sleep -Milliseconds $WaitMs
    $con = $sp.ReadExisting()
} finally { $sp.Close() }
Write-Output '--- console after con ---'
Write-Output $con
$banner = $con -match 'rtlnet[>#]'
$ok = $tclPass -and $banner
Write-Output ("JTAG_LOAD_ELF: {0} (xsdb {1}, CLI prompt {2})" -f ($(if ($ok) { 'PASS' } else { 'FAIL' }), $tclPass, $banner))
if ($ok) { exit 0 } else { exit 1 }
