<#
-------------------------------------------------------------------------------
File: merge_elf.ps1
Purpose: put the MicroBlaze firmware ELF into the LMB block RAM of the
  Nexys Video bitstream with updatemem, producing the bitstream to program.
Overview:
  * Inputs (defaults): build/rtlnet_nexys_video_hw.bit and
    build/rtlnet_nexys_video.mmi from build_bitstream.tcl, and
    microblaze/firmware/build/firmware.elf.
  * Verifies the MMI before use: one processor, InstPath
    u_cpu/u_bd/rtlnet_cpu_i/microblaze_0, little endian, an LMB address space
    of 0..524287 (512 KiB) with 128 RAMB36 bit lanes (other address spaces,
    the AXI BRAM, may follow); and that the ELF exists and
    is newer than nothing stale (prints size, time and SHA-256 of each file).
  * Runs updatemem -force -meminfo <mmi> -data <elf> -bit <bit>
    -proc <InstPath> -out build/rtlnet_nexys_video.bit; exit code 0 only when
    updatemem succeeded and the output exists.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/merge_elf.ps1 `
    [-Elf <elf>] [-Mmi <mmi>] [-Bit <bit>] [-Out <bit>]
Revision: 10-22-2026
  * 10-22-2026: initial version.
  * 10-22-2026: 512 KiB LMB (128 RAMB36); further address spaces allowed.
-------------------------------------------------------------------------------
#>
param(
    [string]$Elf = '',
    [string]$Mmi = '',
    [string]$Bit = '',
    [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
$Build = Join-Path $Board 'build'
if (-not $Elf) { $Elf = Join-Path $Repo 'microblaze\firmware\build\firmware.elf' }
if (-not $Mmi) { $Mmi = Join-Path $Build 'rtlnet_nexys_video.mmi' }
if (-not $Bit) { $Bit = Join-Path $Build 'rtlnet_nexys_video_hw.bit' }
if (-not $Out) { $Out = Join-Path $Build 'rtlnet_nexys_video.bit' }
$UpdateMem = 'C:\Xilinx\2025.2\Vivado\bin\updatemem.bat'
$ExpectProc = 'u_cpu/u_bd/rtlnet_cpu_i/microblaze_0'

function Fail([string]$m) { Write-Output "RTLNET_MERGE: FAIL $m"; exit 1 }
function Describe([string]$label, [string]$p) {
    $f = Get-Item -LiteralPath $p
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.Substring(0, 16)
    Write-Output ("  {0,-10} {1}  {2,9} bytes  {3:yyyy-MM-dd HH:mm:ss}  sha256 {4}" -f $label, $f.FullName, $f.Length, $f.LastWriteTime, $h)
}

foreach ($p in @($Elf, $Mmi, $Bit)) { if (-not (Test-Path -LiteralPath $p)) { Fail "missing $p" } }
if (-not (Test-Path -LiteralPath $UpdateMem)) { Fail "updatemem not found at $UpdateMem" }

# MMI checks: the processor and block RAM names this build expects.
[xml]$x = Get-Content -LiteralPath $Mmi -Raw
$procs = @($x.MemInfo.Processor)
if ($procs.Count -ne 1) { Fail "MMI lists $($procs.Count) processors, expected 1" }
$proc = $procs[0].InstPath
if ($proc -ne $ExpectProc) { Fail "MMI processor '$proc', expected '$ExpectProc'" }
if ($procs[0].Endianness -ne 'Little') { Fail "MMI endianness '$($procs[0].Endianness)', expected Little" }
$spaces = @($procs[0].AddressSpace)
$space = @($spaces | Where-Object { [int64]$_.Begin -eq 0 })[0]
if (-not $space -or [int64]$space.End -ne 524287) { Fail "MMI has no LMB address space 0..524287" }
foreach ($s in $spaces) { Write-Output ("RTLNET_MERGE: MMI address space {0} {1}..{2}" -f $s.Name, $s.Begin, $s.End) }
$lanes = @($space.SelectNodes('.//BitLane'))
$ramb  = @($lanes | Where-Object { $_.MemType -eq 'RAMB36' })
if ($lanes.Count -ne 128 -or $ramb.Count -ne 128) { Fail "MMI LMB space has $($lanes.Count) bit lanes ($($ramb.Count) RAMB36), expected 128 RAMB36" }
Write-Output "RTLNET_MERGE: MMI processor $proc, LMB 0..524287, $($ramb.Count) RAMB36 lanes"
Describe 'elf' $Elf
Describe 'mmi' $Mmi
Describe 'bit (hw)' $Bit

if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
$log = Join-Path $Build 'merge_elf.log'
# updatemem writes side files into its working directory: run it in build/.
Push-Location $Build
try {
    & $UpdateMem -force -meminfo $Mmi -data $Elf -bit $Bit -proc $proc -out $Out *> $log
    $rc = $LASTEXITCODE
} finally {
    Pop-Location
}
Get-Content -LiteralPath $log | Where-Object { $_ -match 'ERROR|WARNING|Loading|Writing|updatemem' } | ForEach-Object { Write-Output "  | $_" }
if ($rc -ne 0) { Fail "updatemem exit $rc (log $log)" }
if (-not (Test-Path -LiteralPath $Out)) { Fail "updatemem wrote no $Out" }
Describe 'bit (out)' $Out
Write-Output "RTLNET_MERGE: PASS $Out"
exit 0
