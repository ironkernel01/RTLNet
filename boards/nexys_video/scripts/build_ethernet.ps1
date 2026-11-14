<#
-------------------------------------------------------------------------------
File: build_ethernet.ps1
Purpose: one-command build of the Nexys Video Ethernet demo image (rtlnet_nexys_video_eth_top): bitstream (Vivado,
  gated) with its hardware export (XSA), firmware ELF of cpu/microblaze_v_ethernet on the BSP generated from that XSA,
  firmware merged into the block RAM, and optionally JTAG programming. The H.264 design's build.ps1 is not involved.
Overview:
  1. build_ethernet.tcl through scripts/rtlnet_vivado.ps1 (machine-wide Vivado slot); BUILD_ID from git rev-parse
     --short=8 HEAD and the dirty flag from git status, both inside the Tcl. Writes rtlnet_nexys_video_eth.xsa,
     rtlnet_nexys_video_eth.mmi, rtlnet_nexys_video_eth_hw.bit and build_info.txt.
  2. cpu/microblaze_v_ethernet/firmware/build.ps1 -Demo -Xsa <xsa> -OutDir <build folder>/firmware: CLI table check,
     BSP from the XSA (Vitis), firmware.elf, host harness and its scripted demo (TEST PASS required), host unit tests.
  3. merge_elf.ps1 with this design's ELF, MMI and processor path: updatemem -> rtlnet_nexys_video_eth.bit.
  4. -Program: program.ps1 -Bit (JTAG only, machine-wide board lock).
  * Outputs: boards/nexys_video/build/ (no -Tag) or boards/nexys_video/build/<tag>/ (-Tag), always under the
    rtlnet_nexys_video_eth.* names, so the H.264 design's rtlnet_nexys_video.* files are never overwritten. The
    firmware build writes into <build folder>/firmware (BSP, objects, ELF).
  * Exit code 0 only when every step passed; otherwise the failing step's code (the Vivado gate codes are listed in
    build_ethernet.tcl).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/build_ethernet.ps1 `
    [-Tag <name>] [-CommonClk 2] [-CpuClkHz 100000000] [-LmbKb 512] [-CpuOpt 0] [-CpuBtc 0] [-CpuMuldiv 1]
    [-SkipBitstream] [-SkipFirmware] [-Program]
  * -SkipBitstream: reuse the bitstream, MMI and XSA already in the build folder (firmware and merge only).
  * -CommonClk: 2 (default) = one system clock at -CpuClkHz (100 MHz) for the CPU, the protocol and the MAC client side (clk125 and clk125_90
    only the RGMII transmit side); 0 = the multi-clock tree.
  * -CpuClkHz: the system (CPU) clock (100 MHz default; the MMCM divider is 1000 MHz / CpuClkHz and the block
    design is built for it). -LmbKb: size of the LMB block RAM in KiB (code, data, lwIP pools and stack), 512 default.
  * -LmbBuf 1 (default): the frame buffer RAM is a true dual-port block RAM, the CPU on the data-side LMB at 0x00100000, the DMA on
    the AXI side at 0xC0000000; -BufKb its size (128 KiB default). 0: the CPU reaches the buffer RAM over M_AXI_DP (the firmware
    of this tree then does not match: build it from an earlier commit).
  * -CpuOpt (0 performance, 1 area, 2 frequency pipeline), -CpuBtc (branch target cache size 0..7), -CpuMuldiv (0..2):
    MicroBlaze V configuration (IP property values of the 2026.1 IP).
Revision: 11-14-2026
  * 11-14-2026: -CommonClk, -CpuOpt, -CpuBtc, -CpuMuldiv.
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string]$Tag = '',
    [ValidateSet(0, 2)][int]$CommonClk = 2,
    [int]$CpuClkHz = 100000000,
    [int]$LmbKb = 512,
    [ValidateSet(0, 1, 2)][int]$CpuOpt = 0,
    [ValidateRange(0, 7)][int]$CpuBtc = 0,
    [ValidateSet(0, 1, 2)][int]$CpuMuldiv = 1,
    [ValidateSet(0, 1)][int]$LmbBuf = 1,
    [ValidateSet(16, 32, 64, 128)][int]$BufKb = 128,
    [switch]$SkipBitstream,
    [switch]$SkipFirmware,
    [switch]$Program
)
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
$Build = Join-Path $Board 'build'
if ($Tag) { $Build = Join-Path $Build $Tag }
New-Item -ItemType Directory -Force -Path $Build | Out-Null
if ($Program) {
    . (Join-Path $Repo 'scripts\rtlnet_board_lock.ps1')
    Enter-RtlnetBoardLock -Purpose 'build and program the Ethernet demo' -ExpectedMinutes 60
}

function Step([string]$name, [scriptblock]$body) {
    Write-Output "=== $name"
    $t0 = Get-Date
    & $body
    $rc = $LASTEXITCODE
    Write-Output ("=== {0}: exit {1} ({2:N0} s)" -f $name, $rc, ((Get-Date) - $t0).TotalSeconds)
    if ($rc -ne 0) { Write-Output "RTLNET_BUILD_ETH: FAIL at '$name' (exit $rc)"; exit $rc }
}

$xsa = Join-Path $Build 'rtlnet_nexys_video_eth.xsa'
$mmi = Join-Path $Build 'rtlnet_nexys_video_eth.mmi'
$hw  = Join-Path $Build 'rtlnet_nexys_video_eth_hw.bit'
$bit = Join-Path $Build 'rtlnet_nexys_video_eth.bit'
$fwOut = Join-Path $Build 'firmware'

if (-not $SkipBitstream) {
    $tclArgs = "common_clk,$CommonClk,cpu_clk_hz,$CpuClkHz,lmb_kb,$LmbKb,cpu_opt,$CpuOpt,cpu_btc,$CpuBtc,cpu_muldiv,$CpuMuldiv,lmb_buf,$LmbBuf,buf_kb,$BufKb"
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
    powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'merge_elf.ps1') `
        -Elf (Join-Path $fwOut 'firmware.elf') -Mmi $mmi -Bit $hw -Out $bit `
        -ProcPath 'u_cpu/u_bd/rtlnet_cpu_eth_bd_i/microblaze_0' -LmbBytes ($LmbKb * 1024) -WorkDir $Build
}
if ($Program) {
    Step 'program' { powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'program.ps1') -Bit $bit }
}
Write-Output '--- build_info.txt'
Get-Content -LiteralPath (Join-Path $Build 'build_info.txt') | ForEach-Object { Write-Output "  $_" }
Write-Output "RTLNET_BUILD_ETH: PASS $bit"
exit 0
