<#
-------------------------------------------------------------------------------
File: build.ps1
Purpose: one-command build of the RTLNet Nexys Video image: bitstream
  (Vivado, gated) with its hardware export (XSA), firmware ELF on the BSP
  generated from that XSA, firmware merged into the block RAM, and
  optionally JTAG programming and the console test.
Overview:
  1. build_bitstream.tcl through scripts/rtlnet_vivado.ps1 (machine-wide
     Vivado slot); BUILD_ID from git rev-parse --short=8 HEAD and the dirty
     flag from git status, both inside the Tcl. -Network defines
     RTLNET_WITH_NETWORK (needs the network cores' filelists). Writes
     build/rtlnet_nexys_video.xsa (write_hw_platform -fixed).
  2. cpu/microblaze_v_h264/firmware/build.ps1 -Demo -Xsa build/rtlnet_nexys_video.xsa:
     CLI table check, BSP from the XSA (Vitis), firmware.elf, host harness
     and its scripted demo (TEST PASS required).
  3. merge_elf.ps1: updatemem -> build/rtlnet_nexys_video.bit.
  4. -Program: program.ps1 (JTAG). -Test: cli_test.ps1 on -Port (implies
     -Program).
  * Paths derive from this script's location; outputs in boards/nexys_video/build.
  * Exit code 0 only when every step passed; otherwise the failing step's
    code (the Vivado gate codes are listed in build_bitstream.tcl).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/build.ps1 `
    [-Network] [-SkipFirmware] [-Program] [-Test] [-Port COM3] [-Tag <name>] [-Image] [-HighProfile none|full|demo] [-HpTools cabac|t8|all]
  * -Tag <name>: variant gate build. Only the bitstream step runs, with every output (log, reports, hardware
    bitstream, MMI, XSA, build_info.txt) in build/<name>/; the network image build/rtlnet_nexys_video.{bit,mmi,xsa}
    and the firmware build are untouched. Example: -Tag cpu (the cpu-only variant, no -Network).
  * -Image (with -Tag): the tagged build also builds the firmware on the BSP of the tagged XSA and merges it into the tagged bitstream, giving
    build/<name>/rtlnet_nexys_video.bit (program it with program.ps1 -Bit). The default image in build/ is still not touched. Example:
    -Network -HighProfile demo -Tag hp_demo -Image.
  * -HighProfile <none|full|demo> (default none): none is the flow above, unchanged. full or demo builds rtlnet_h264_top with HIGH_PROFILE 1 and
    the netlist of that variant from the High profile repository (H264HighProfile\netlist\<variant>, found through $env:H264_HIGHPROFILE_ROOT or
    next to this repository); the build refuses to start when the netlist is missing. none = the CAVLC Baseline encoder alone (no High profile netlist).
    full = High profile without a time limit, demo = High profile that ends 30 minutes after configuration (the encoder then falls back to Baseline).
  * -HpTools <cabac|t8|all> (default all; only with -HighProfile full|demo): which tools the High profile build contains. CABAC entropy coding is always
    included with -HighProfile. cabac = CABAC only; t8 = CABAC + the 8x8 transform for inter macroblocks; all = CABAC + 8x8 transform + the per-macroblock
    choice between the 4x4 and the 8x8 transform. -HpTools picks the netlist (netlist\<variant> for all, netlist\<variant>_<tools> for the others) and sets
    the encoder parameters HP_T8 and HP_T8_AUTO to match: the netlist and the encoder always carry the same tool set. Software reads the set from hp_caps.
    The deblocking filter is not part of this choice (it is the DEBLOCK parameter of rtlnet_h264_top, on by default).
Revision: 11-14-2026
  * 11-14-2026: moved to cpu/microblaze_v_h264/ (was microblaze/).
  * 11-12-2026: -HpTools (tool set of the High profile build: netlist and the HP_T8 / HP_T8_AUTO parameters).
  * 11-11-2026: -Image (tagged build with firmware and merge).
  * 11-11-2026: -HighProfile.
  * 11-09-2026: -Program and -Test take the machine-wide board lock first (rtlnet_board_lock.ps1).
  * 10-22-2026: initial version.
  * 10-22-2026: bitstream before firmware (the BSP comes from the XSA).
  * 11-09-2026: -Tag: variant build into build/<name>/.
-------------------------------------------------------------------------------
#>
param(
    [switch]$Network,
    [switch]$SkipFirmware,
    [switch]$Image,
    [switch]$Program,
    [switch]$Test,
    [string]$Port = 'COM3',
    [string]$Tag = '',
    [ValidateSet('none', 'full', 'demo')][string]$HighProfile = 'none',
    [ValidateSet('cabac', 't8', 'all')][string]$HpTools = 'all'
)
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
& (Join-Path $Repo 'scripts/resolve_media.ps1')
$Build = Join-Path $Board 'build'
New-Item -ItemType Directory -Force -Path $Build | Out-Null
if ($Program -or $Test) {
    . (Join-Path $Repo 'scripts\rtlnet_board_lock.ps1')
    Enter-RtlnetBoardLock -Purpose 'build, program and test' -ExpectedMinutes 60
}

function Step([string]$name, [scriptblock]$body) {
    Write-Output "=== $name"
    $t0 = Get-Date
    & $body
    $rc = $LASTEXITCODE
    Write-Output ("=== {0}: exit {1} ({2:N0} s)" -f $name, $rc, ((Get-Date) - $t0).TotalSeconds)
    if ($rc -ne 0) { Write-Output "RTLNET_BUILD: FAIL at '$name' (exit $rc)"; exit $rc }
}

$net = $(if ($Network) { '1' } else { '0' })
$tclArgs = "network,$net"
$hpArgs = ''
if ($HighProfile -ne 'none') {
    $hpRoot = if ($env:H264_HIGHPROFILE_ROOT) { $env:H264_HIGHPROFILE_ROOT } else { Join-Path $Repo '..\H264HighProfile' }
    $hpName = if ($HpTools -eq 'all') { $HighProfile } else { "${HighProfile}_$HpTools" }
    $hpNetlist = Join-Path $hpRoot "netlist\$hpName"
    if (-not (Test-Path -LiteralPath (Join-Path $hpNetlist 'rtlnet_h264_hp.edf'))) {
        Write-Output "RTLNET_BUILD: FAIL no High profile netlist at $hpNetlist (build it with scripts\build_netlist.ps1 -Variant $HighProfile -Tools $HpTools in the High profile repository)"
        exit 99
    }
    $hpArgs = ",highprofile,$HighProfile,hp_netlist," + ((Resolve-Path -LiteralPath $hpNetlist).Path -replace '\\', '/')
    $hpArgs += ",hp_t8,$(if ($HpTools -eq 'cabac') { 0 } else { 1 }),hp_t8_auto,$(if ($HpTools -eq 'all') { 1 } else { 0 })"
    $tclArgs = "network,$net$hpArgs"
}
if ($Tag) {
    if (($Program -or $Test) -and -not $Image) { Write-Output 'RTLNET_BUILD: FAIL -Tag builds are not programmed (no firmware merge; use -Image, then program.ps1 -Bit)'; exit 99 }
    if (($Program -or $Test) -and $Image) { Write-Output 'RTLNET_BUILD: FAIL -Tag -Image builds are programmed with program.ps1 -Bit build/<tag>/rtlnet_nexys_video.bit'; exit 99 }
    $Build = Join-Path $Build $Tag
    New-Item -ItemType Directory -Force -Path $Build | Out-Null
    $tclArgs = "network,$net,tag,$Tag$hpArgs"
}
Step 'bitstream' {
    & (Join-Path $Repo 'scripts\rtlnet_vivado.ps1') -Tcl (Join-Path $PSScriptRoot 'build_bitstream.tcl') `
        -Log (Join-Path $Build 'build_bitstream.log') -TclArgs $tclArgs
}
Get-Content -LiteralPath (Join-Path $Build 'build_bitstream.log') | Where-Object { $_ -match '^(rtlnet_build|rtlnet_cdc):' } |
    ForEach-Object { Write-Output "  $_" }
if ($Tag -and $Image) {
    Step 'firmware' { powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'cpu\microblaze_v_h264\firmware\build.ps1') -Demo `
        -Xsa (Join-Path $Build 'rtlnet_nexys_video.xsa') }
    Step 'merge' { powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'merge_elf.ps1') `
        -Mmi (Join-Path $Build 'rtlnet_nexys_video.mmi') -Bit (Join-Path $Build 'rtlnet_nexys_video_hw.bit') -Out (Join-Path $Build 'rtlnet_nexys_video.bit') }
    Write-Output '--- build_info.txt'
    Get-Content -LiteralPath (Join-Path $Build 'build_info.txt') | ForEach-Object { Write-Output "  $_" }
    Write-Output "RTLNET_BUILD: PASS $(Join-Path $Build 'rtlnet_nexys_video.bit') (tag $Tag, firmware merged)"
    exit 0
}
if ($Tag) {
    Write-Output '--- build_info.txt'
    Get-Content -LiteralPath (Join-Path $Build 'build_info.txt') | ForEach-Object { Write-Output "  $_" }
    Write-Output "RTLNET_BUILD: PASS $(Join-Path $Build 'rtlnet_nexys_video_hw.bit') (variant $Tag, no firmware)"
    exit 0
}
if (-not $SkipFirmware) {
    Step 'firmware' { powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'cpu\microblaze_v_h264\firmware\build.ps1') -Demo `
        -Xsa (Join-Path $Build 'rtlnet_nexys_video.xsa') }
}
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
