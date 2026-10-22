<#
-------------------------------------------------------------------------------
File: build.ps1
Purpose: build the RTLNet Nexys Video firmware (MicroBlaze, mb-gcc, no vendor
  BSP) into build/firmware.elf, and the CLI desktop harness (host gcc) into
  build/menu.exe.
Overview:
  * Default: check the CLI tables against cli/cli_commands.txt, build the
    firmware ELF, print its section sizes.
  * -HostHarness: also build build/menu.exe (stdin/stdout harness, register model).
  * -Demo: build the harness and run its scripted --demo session; the exit
    code follows the anchored TEST PASS / TEST FAIL line.
  * -NoFirmware: skip the MicroBlaze build (harness only).
  * Exit code 0 only when every requested step succeeded.
  * Compiler flags match the block design (cores/rtlnet_cpu_microblaze/hdl/
    rtlnet_cpu_bd.tcl): little endian, barrel shifter, pattern compare,
    hardware multiplier and divider, no FPU.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File firmware/nexys_video/build.ps1 [-HostHarness] [-Demo] [-NoFirmware]
Revision: 10-22-2026
  * 10-22-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [switch]$HostHarness,
    [switch]$Demo,
    [switch]$NoFirmware
)
$ErrorActionPreference = 'Stop'
$Fw     = $PSScriptRoot
$Repo   = (Resolve-Path (Join-Path $Fw '..\..')).Path
$Out    = Join-Path $Fw 'build'
$MbBin  = 'C:/Xilinx/2025.2/gnu/microblaze/nt/bin'
$MbGcc  = Join-Path $MbBin 'mb-gcc.exe'
$MbSize = Join-Path $MbBin 'mb-size.exe'
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Invoke-Step([string]$exe, [string[]]$argv) {
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { throw "failed ($LASTEXITCODE): $exe $($argv -join ' ')" }
}

$inc = @(
    "-I$Fw/src", "-I$Fw/cli",
    "-I$Repo/cores/rtlnet_common/driver",
    "-I$Repo/cores/rtlnet_cpu_microblaze/driver"
)
$common = @('-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic')

# 1. The generated CLI tables must match the command file.
Invoke-Step 'python' @("$Fw/cli/check_menu.py")

# 2. MicroBlaze firmware.
if (-not $NoFirmware) {
    $mbflags = @('-mcpu=v11.0', '-mlittle-endian', '-mxl-barrel-shift', '-mxl-pattern-compare',
                 '-mno-xl-soft-mul', '-mno-xl-soft-div')
    $cflags  = $common + @('-Os', '-g', '-ffreestanding', '-ffunction-sections', '-fdata-sections')
    $srcs = @(
        'src/crt0.S', 'src/main.c', 'src/rtlnet_platform.c', 'src/uart_lite.c', 'src/timer.c',
        'src/rtlnet_board.c', 'src/rtlnet_fmt.c', 'src/rtlnet_string.c',
        'cli/menu.c', 'cli/menu_table.c', 'cli/cli_commands.c'
    )
    $objs = @()
    $objDir = Join-Path $Out 'obj'
    New-Item -ItemType Directory -Force -Path $objDir | Out-Null
    foreach ($s in $srcs) {
        $o = Join-Path $objDir (([System.IO.Path]::GetFileNameWithoutExtension($s)) + '.o')
        Invoke-Step $MbGcc ($mbflags + $cflags + $inc + @('-c', "$Fw/$s", '-o', $o))
        $objs += $o
    }
    $elf = Join-Path $Out 'firmware.elf'
    Invoke-Step $MbGcc ($mbflags + @('-nostdlib', '-nostartfiles', "-T$Fw/src/rtlnet_fw.ld",
        '-Wl,--gc-sections', "-Wl,-Map=$Out/firmware.map", '-o', $elf) + $objs + @('-lgcc'))
    & $MbSize $elf
    Write-Output "RTLNET_FW: PASS $elf"
}

# 3. Desktop harness (host gcc): the same engine, callbacks and board layer
#    against a register model.
if ($HostHarness -or $Demo) {
    $hsrcs = @('host/main.c', 'host/host_platform.c', 'src/rtlnet_board.c', 'src/rtlnet_fmt.c',
               'cli/menu.c', 'cli/menu_table.c', 'cli/cli_commands.c')
    $exe = Join-Path $Out 'menu.exe'
    Invoke-Step 'gcc' ($common + @('-O2', '-DRTLNET_HOST_TEST', "-I$Fw/host") + $inc +
        ($hsrcs | ForEach-Object { "$Fw/$_" }) + @('-o', $exe))
    Write-Output "RTLNET_HOST: built $exe"
    if ($Demo) {
        # Negative control first: the injected failure must be reported.
        $neg = & $exe --demo --inject-failure
        $negVerdict = $neg | Where-Object { $_ -match '^TEST (PASS|FAIL): ' } | Select-Object -Last 1
        if ($LASTEXITCODE -eq 0 -or $negVerdict -notmatch '^TEST FAIL: ') {
            throw "host demo negative control did not report TEST FAIL"
        }
        Write-Output "RTLNET_HOST: negative control: $negVerdict"
        $log = & $exe --demo
        $rc = $LASTEXITCODE
        $log | ForEach-Object { Write-Output $_ }
        $verdict = $log | Where-Object { $_ -match '^TEST (PASS|FAIL): ' } | Select-Object -Last 1
        if ($rc -ne 0 -or -not $verdict -or $verdict -notmatch '^TEST PASS: ') {
            throw "host demo did not pass"
        }
    }
}
exit 0
