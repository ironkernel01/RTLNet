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
    (connect, Hart #0, stop, PC and a0, reset, wait for DDR3 calibration,
    dow, download verification, con), then reads the port for
    -WaitMs and prints it. The boot banner and the CLI prompt are the proof
    that the loaded ELF runs: the line "JTAG_LOAD_ELF: PASS" needs the Tcl
    PASS line, a CLI prompt (rtlnet>) on the port and the banner of the image.
  * -Image: LMB (release image, linked at 0x0), DDR3 (development image of
    microblaze/firmware/build.ps1 -Ddr, linked at 0x8000_0000) or Auto (the
    default: the ELF entry address decides). A DDR3 image must print
    "DDR3 image" in its boot banner. An LMB image must not print it; it passes
    with "LMB image" or, for a release ELF built before the image name was added to
    the banner, with a banner that carries no image name.
  * Needs the FPGA programmed with the MicroBlaze V image (program.ps1).
  * Exit code 0 on PASS, 1 on FAIL.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/jtag_load_elf.ps1 `
    [-Elf <elf>] [-Image Auto|LMB|DDR3] [-Port COM3] [-Baud 115200] [-WaitMs 4000] [-CalibTimeoutMs 10000]
Revision: 11-09-2026
  * 11-09-2026: initial version.
  * 11-09-2026: -Image (banner check of the LMB and DDR3 images), -CalibTimeoutMs (DDR3 calibration wait of the Tcl).
-------------------------------------------------------------------------------
#>
param(
    [string]$Elf = '',
    [string]$Port = 'COM3',
    [int]$Baud = 115200,
    [int]$WaitMs = 4000,
    [ValidateSet('Auto', 'LMB', 'DDR3')][string]$Image = 'Auto',
    [int]$CalibTimeoutMs = 10000
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
if (-not $Elf) { $Elf = Join-Path $Repo 'microblaze\firmware\build\firmware.elf' }
if (-not (Test-Path -LiteralPath $Elf)) { Write-Output "JTAG_LOAD_ELF: FAIL missing $Elf"; exit 1 }
$Elf = (Resolve-Path -LiteralPath $Elf).Path
if ($Image -eq 'Auto') {
    # ELF32 little endian: e_entry is the 32-bit word at file offset 24.
    $hdr = [System.IO.File]::ReadAllBytes($Elf)[0..27]
    $entry = [uint64][BitConverter]::ToUInt32($hdr, 24)
    # 0x80000000 is an Int32 (negative) in PowerShell 5.1: compare as UInt64.
    $Image = $(if ($entry -ge [uint64]2147483648) { 'DDR3' } else { 'LMB' })
    Write-Output ("JTAG_LOAD_ELF: image {0} (entry 0x{1:x8})" -f $Image, $entry)
}
$xsdb = Join-Path (Resolve-RtlnetXilinx).Vitis 'bin/xsdb.bat'
if (-not (Test-Path -LiteralPath $xsdb)) { Write-Output "JTAG_LOAD_ELF: FAIL no xsdb at $xsdb"; exit 1 }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
try { $sp.Open() } catch { Write-Output "JTAG_LOAD_ELF: FAIL cannot open ${Port}: $($_.Exception.Message)"; exit 1 }
try {
    [void]$sp.ReadExisting()
    $out = & $xsdb (Join-Path $PSScriptRoot 'jtag_load_elf.tcl') ($Elf -replace '\\', '/') $CalibTimeoutMs 2>&1 | Out-String
    $out -split "`r?`n" | Where-Object { $_ -match '^rtlnet_jtag:' } | ForEach-Object { Write-Output $_ }
    $tclPass = $out -match '(?m)^rtlnet_jtag: PASS'
    Start-Sleep -Milliseconds $WaitMs
    $con = $sp.ReadExisting()
} finally { $sp.Close() }
Write-Output '--- console after con ---'
Write-Output $con
$prompt = $con -match 'rtlnet[>#]'
$isDdr = $con -match 'DDR3 image'
$imageOk = $(if ($Image -eq 'DDR3') { $isDdr } else { -not $isDdr })
$ok = $tclPass -and $prompt -and $imageOk
Write-Output ("JTAG_LOAD_ELF: {0} (xsdb {1}, CLI prompt {2}, banner image {3}: {4})" -f ($(if ($ok) { 'PASS' } else { 'FAIL' }), $tclPass, $prompt, $Image, $imageOk))
if ($ok) { exit 0 } else { exit 1 }
