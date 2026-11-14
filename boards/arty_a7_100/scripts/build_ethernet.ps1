<#
-------------------------------------------------------------------------------
File: build_ethernet.ps1
Purpose: one-command build of the Arty A7-100T Ethernet demo image (rtlnet_arty_a7_100_eth_top): bitstream (Vivado,
  gated) with its hardware export (XSA), firmware ELF of cpu/microblaze_v_ethernet on the BSP generated from that XSA
  (the small-memory profile, 256 KiB LMB), and the firmware merged into the block RAM.
Overview:
  1. build_ethernet.tcl through scripts/rtlnet_vivado.ps1 (machine-wide Vivado slot); BUILD_ID from git rev-parse
     --short=8 HEAD and the dirty flag from git status, both inside the Tcl. Writes rtlnet_arty_a7_100_eth.xsa,
     rtlnet_arty_a7_100_eth.mmi, rtlnet_arty_a7_100_eth_hw.bit and build_info.txt.
  2. cpu/microblaze_v_ethernet/firmware/build.ps1 -Demo -Xsa <xsa> -OutDir <firmware folder> -LmbKb -BufKb: CLI table check,
     BSP from the XSA (Vitis), firmware.elf, host harness and its scripted demo (TEST PASS required), host unit tests.
  3. merge_elf.ps1 (boards/nexys_video/scripts, board independent: it takes the processor path and the LMB size as
     arguments) with this design's ELF, MMI and processor path: updatemem -> rtlnet_arty_a7_100_eth.bit.
  * Outputs: boards/arty_a7_100/build/ (no -Tag) or boards/arty_a7_100/build/<tag>/ (-Tag). The firmware build writes into
    <build folder>/firmware (BSP, objects, ELF) unless -FwOutDir names a folder.
  * Exit code 0 only when every step passed; otherwise the failing step's code (the Vivado gate codes are listed in
    build_ethernet.tcl).
  * The board is not programmed by this script: load rtlnet_arty_a7_100_eth.bit with the Vivado hardware manager or program the
    Quad-SPI flash (README, section Programming).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/arty_a7_100/scripts/build_ethernet.ps1 `
    [-Tag <name>] [-CpuClkHz 100000000] [-LmbKb 256] [-BufKb 64] [-CpuOpt 0] [-CpuBtc 0] [-CpuMuldiv 1] [-LmbBuf 1]
    [-SkipBitstream] [-SkipFirmware] [-FwOutDir <dir>]
  * -SkipBitstream: reuse the bitstream, MMI and XSA already in the build folder (firmware and merge only).
  * -CpuClkHz: the one system clock (100 MHz default; the MMCM divider is 1000 MHz / CpuClkHz and the block design is built for it).
  * -LmbKb: size of the LMB block RAM in KiB (code, data, lwIP pools and stack), 256 default (the firmware selects its small-memory
    profile for 256 and below). -BufKb: the frame buffer RAM, a true dual-port block RAM (the CPU on the data-side LMB at 0x00100000,
    the DMA on the AXI side at 0xC0000000), 64 KiB default.
  * -CpuOpt (0 performance, 1 area, 2 frequency pipeline), -CpuBtc (branch target cache size 0..7), -CpuMuldiv (0..2): MicroBlaze V
    configuration (IP property values of the 2026.1 IP).
  * -FwOutDir: folder of the firmware build (default <build folder>/firmware). The BSP flow fails on object paths above about 250
    characters: a checkout deep in a long path (a git worktree) needs a short folder here.
Revision: 11-14-2026
  * 11-14-2026: initial version (derived from boards/nexys_video/scripts/build_ethernet.ps1: Arty A7-100T, small-memory
    defaults, no clock tree option, -FwOutDir, no -Program).
-------------------------------------------------------------------------------
#>
param(
    [string]$Tag = '',
    [int]$CpuClkHz = 100000000,
    [int]$LmbKb = 256,
    [ValidateSet(0, 1, 2)][int]$CpuOpt = 0,
    [ValidateRange(0, 7)][int]$CpuBtc = 0,
    [ValidateSet(0, 1, 2)][int]$CpuMuldiv = 1,
    [ValidateSet(0, 1)][int]$LmbBuf = 1,
    [ValidateSet(16, 32, 64, 128)][int]$BufKb = 64,
    [switch]$SkipBitstream,
    [switch]$SkipFirmware,
    [string]$FwOutDir = ''
)
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
$Build = Join-Path $Board 'build'
if ($Tag) { $Build = Join-Path $Build $Tag }
New-Item -ItemType Directory -Force -Path $Build | Out-Null

function Step([string]$name, [scriptblock]$body) {
    Write-Output "=== $name"
    $t0 = Get-Date
    & $body
    $rc = $LASTEXITCODE
    Write-Output ("=== {0}: exit {1} ({2:N0} s)" -f $name, $rc, ((Get-Date) - $t0).TotalSeconds)
    if ($rc -ne 0) { Write-Output "RTLNET_BUILD_ETH: FAIL at '$name' (exit $rc)"; exit $rc }
}

$xsa = Join-Path $Build 'rtlnet_arty_a7_100_eth.xsa'
$mmi = Join-Path $Build 'rtlnet_arty_a7_100_eth.mmi'
$hw  = Join-Path $Build 'rtlnet_arty_a7_100_eth_hw.bit'
$bit = Join-Path $Build 'rtlnet_arty_a7_100_eth.bit'
$fwOut = if ($FwOutDir) { $FwOutDir } else { Join-Path $Build 'firmware' }

if (-not $SkipBitstream) {
    $tclArgs = "cpu_clk_hz,$CpuClkHz,lmb_kb,$LmbKb,cpu_opt,$CpuOpt,cpu_btc,$CpuBtc,cpu_muldiv,$CpuMuldiv,lmb_buf,$LmbBuf,buf_kb,$BufKb"
    if ($Tag) { $tclArgs += ",tag,$Tag" }
    Step 'bitstream' {
        & (Join-Path $Repo 'scripts\rtlnet_vivado.ps1') -Tcl (Join-Path $PSScriptRoot 'build_ethernet.tcl') `
            -Log (Join-Path $Build 'build_bitstream.log') -TclArgs $tclArgs
    }
    Get-Content -LiteralPath (Join-Path $Build 'build_bitstream.log') | Where-Object { $_ -match '^(rtlnet_build|rtlnet_cdc):' } |
        ForEach-Object { Write-Output "  $_" }
}
foreach ($p in @($xsa, $mmi, $hw)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Output "RTLNET_BUILD_ETH: FAIL missing $p (build the bitstream first)"; exit 99 }
}
if (-not $SkipFirmware) {
    Step 'firmware' {
        powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'cpu\microblaze_v_ethernet\firmware\build.ps1') -Demo `
            -Xsa $xsa -OutDir $fwOut -LmbKb $LmbKb -BufKb $BufKb
    }
}
Step 'merge' {
    powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'boards\nexys_video\scripts\merge_elf.ps1') `
        -Elf (Join-Path $fwOut 'firmware.elf') -Mmi $mmi -Bit $hw -Out $bit `
        -ProcPath 'u_cpu/u_bd/rtlnet_cpu_eth_bd_i/microblaze_0' -LmbBytes ($LmbKb * 1024) -WorkDir $Build
}
Write-Output '--- build_info.txt'
Get-Content -LiteralPath (Join-Path $Build 'build_info.txt') | ForEach-Object { Write-Output "  $_" }
Write-Output "RTLNET_BUILD_ETH: PASS $bit"
exit 0
