<#
-------------------------------------------------------------------------------
File: build.ps1
Purpose: build the RTLNet MicroBlaze firmware in one command from a clean
  checkout: standalone BSP generated from the hardware export (XSA) by the
  Vitis tools of the AMD install, lwIP and the RTLNet core drivers compiled in
  place, the firmware linked into build/firmware.elf; and the CLI desktop
  harness (host gcc) into build/menu.exe.
Overview:
  1. cli/check_menu.py: the generated CLI tables match cli/cli_commands.txt.
  2. BSP (skipped when build/ws is newer than the XSA, or with -NoFirmware):
     `vitis -s bsp/rtlnet_bsp.py <xsa> build/ws` creates the platform
     component from the XSA (standalone OS on microblaze_0, console
     axi_uartlite_0) and builds it: build/ws/p/microblaze_0/d/bsp/{include,
     lib} (libxil.a, libxilstandalone.a, libxiltimer.a), Xilinx.spec.
     Vivado/bin goes on PATH first (the Vitis server runs sdtgen and lopper
     from there).
  3. Linker script build/lscript.ld generated from the install's MicroBlaze
     template (Vitis/data/embeddedsw/scripts/linker_files/lscript_mb.ld.in):
     vectors, code, data, heap and stack in the LMB BRAM, plus the NOLOAD
     section .axi_bram in the AXI BRAM for the DMA frame buffers.
  4. Compile: firmware (src, cli) and the RTLNet core drivers
     (cores/<core>/driver, in place) with -std=c11 -Wall -Wextra -Werror
     -pedantic; lwIP 2.2.0 core, IPv4 and Ethernet sources from the install
     (Vitis/data/embeddedsw/ThirdParty/sw_services/lwip220_v1_3/src/lwip-2.2.0),
     and its iperf application src/apps/lwiperf/lwiperf.c, in place with
     src/lwip/lwipopts.h. Nothing is copied from the install.
  5. Link with the BSP start-up (crt0/crtinit through Xilinx.spec) and
     libraries; print the section sizes.
  * -HostHarness: also build build/menu.exe (stdin/stdout harness, register
    model, host/host_lwip_stub.c in place of lwIP). -Demo: build the harness
    and run its scripted --demo session; the exit code follows the anchored
    TEST PASS / TEST FAIL line. -NoFirmware: harness only. -Bsp: regenerate
    the BSP even when it is up to date. -Xsa: another hardware export.
  * Exit code 0 only when every requested step succeeded; prints
    RTLNET_FW: PASS <elf>.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File microblaze/firmware/build.ps1 `
    [-Xsa <xsa>] [-Bsp] [-HostHarness] [-Demo] [-NoFirmware]
Revision: 10-22-2026
  * 10-22-2026: initial version.
  * 10-22-2026: generated standalone BSP, lwIP, BSP linker conventions;
    hand-written start-up, UART, timer and string files removed.
-------------------------------------------------------------------------------
#>
param(
    [string]$Xsa = '',
    [switch]$Bsp,
    [switch]$HostHarness,
    [switch]$Demo,
    [switch]$NoFirmware
)
$ErrorActionPreference = 'Stop'
$Fw      = $PSScriptRoot
$Repo    = (Resolve-Path (Join-Path $Fw '..\..')).Path
$Out     = Join-Path $Fw 'build'
$Xilinx  = 'C:/Xilinx/2025.2'
$MbBin   = "$Xilinx/gnu/microblaze/nt/bin"
$MbGcc   = Join-Path $MbBin 'mb-gcc.exe'
$MbSize  = Join-Path $MbBin 'mb-size.exe'
$Vitis   = "$Xilinx/Vitis/bin/vitis.bat"
$Esw     = "$Xilinx/Vitis/data/embeddedsw"
$LwipDir = "$Esw/ThirdParty/sw_services/lwip220_v1_3/src/lwip-2.2.0"
$LdTmpl  = "$Esw/scripts/linker_files/lscript_mb.ld.in"
if (-not $Xsa) { $Xsa = Join-Path $Repo 'boards\nexys_video\build\rtlnet_nexys_video.xsa' }
$Ws      = Join-Path $Out 'ws'
$BspDir  = Join-Path $Ws 'p\microblaze_0\d\bsp'
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Invoke-Step([string]$exe, [string[]]$argv) {
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { throw "failed ($LASTEXITCODE): $([System.IO.Path]::GetFileName($exe)) ... $($argv[-1])" }
}
function Fwd([string]$p) { return ($p -replace '\\', '/') }

# Core drivers (cores/<core>/driver): the only code that touches each core.
$drvCores = @('rtlnet_eth_mac', 'rtlnet_mdio', 'rtlnet_eth_protocol', 'rtlnet_arp', 'rtlnet_icmp',
              'rtlnet_dhcp', 'rtlnet_iperf', 'rtlnet_udp_socket', 'rtlnet_udp_echo', 'rtlnet_classifier')
$drvSrcs = @(
    'cores/rtlnet_eth_mac/driver/rtlnet_eth_mac.c', 'cores/rtlnet_mdio/driver/rtlnet_mdio.c',
    'cores/rtlnet_mdio/driver/rtlnet_phy_rtl8211e.c', 'cores/rtlnet_eth_protocol/driver/rtlnet_eth_protocol.c',
    'cores/rtlnet_arp/driver/rtlnet_arp.c', 'cores/rtlnet_icmp/driver/rtlnet_icmp.c',
    'cores/rtlnet_dhcp/driver/rtlnet_dhcp.c', 'cores/rtlnet_iperf/driver/rtlnet_iperf.c',
    'cores/rtlnet_udp_socket/driver/rtlnet_udp_socket.c', 'cores/rtlnet_udp_echo/driver/rtlnet_udp_echo.c',
    'cores/rtlnet_classifier/driver/rtlnet_classifier.c'
) | Where-Object { Test-Path -LiteralPath (Join-Path $Repo $_) }
$inc = @(
    "-I$Fw/src", "-I$Fw/src/lwip", "-I$Fw/cli",
    "-I$Repo/cores/rtlnet_common/driver",
    "-I$Repo/microblaze/driver"
) + ($drvCores | Where-Object { Test-Path -LiteralPath (Join-Path $Repo "cores/$_/driver") } |
     ForEach-Object { "-I$Repo/cores/$_/driver" })
$common = @('-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic')

# 1. The generated CLI tables must match the command file.
Invoke-Step 'python' @("$Fw/cli/check_menu.py")

if (-not $NoFirmware) {
    # 2. BSP from the XSA.
    if (-not (Test-Path -LiteralPath $Xsa)) { throw "no hardware export at $Xsa (build the bitstream first: boards/nexys_video/scripts/build.ps1)" }
    $marker = Join-Path $Out 'bsp.stamp'
    $fresh = (Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath (Join-Path $BspDir 'lib\libxil.a')) -and
             ((Get-Item -LiteralPath $marker).LastWriteTime -ge (Get-Item -LiteralPath $Xsa).LastWriteTime) -and
             ((Get-Content -LiteralPath $marker -Raw).Trim() -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $Xsa).Hash)
    if ($Bsp -or -not $fresh) {
        # Windows tools of the BSP build fail on object paths above about 250 characters.
        $deepest = (Fwd $BspDir) + '/libsrc/build_configs/gen_bsp/libsrc/standalone/src/CMakeFiles/xilstandalone.dir/microblaze/microblaze_interrupt_handler.c.obj.d'
        if ($deepest.Length -gt 250) { throw "BSP path too long ($($deepest.Length) characters): build from a checkout with a shorter path" }
        if (Test-Path -LiteralPath $Ws) { Remove-Item -Recurse -Force -LiteralPath $Ws }
        if (Test-Path -LiteralPath $marker) { Remove-Item -Force -LiteralPath $marker }
        $env:PATH = "$Xilinx\Vivado\bin;$env:PATH"
        $bspLog = Join-Path $Out 'bsp.log'
        Push-Location $Out
        try {
            & $Vitis -s (Join-Path $Fw 'bsp\rtlnet_bsp.py') (Fwd $Xsa) (Fwd $Ws) *> $bspLog
        } finally {
            Pop-Location
        }
        $verdict = Get-Content -LiteralPath $bspLog | Where-Object { $_ -match '^RTLNET_BSP: ' } | Select-Object -Last 1
        Write-Output "  $verdict"
        if ($verdict -notmatch '^RTLNET_BSP: PASS') { throw "BSP generation failed (log $bspLog)" }
        Set-Content -LiteralPath $marker -Value (Get-FileHash -Algorithm SHA256 -LiteralPath $Xsa).Hash
    } else {
        Write-Output "  RTLNET_BSP: up to date $BspDir"
    }
    $bspInc  = Join-Path $BspDir 'include'
    $bspLib  = Join-Path $BspDir 'lib'
    $bspSpec = Join-Path $BspDir 'Xilinx.spec'

    # Compiler flags of the processor configuration, as the BSP was built.
    $cf = Get-Content -LiteralPath (Join-Path $BspDir 'cflags.yaml') -Raw
    $hw = ([regex]::Match($cf, 'cflags:\s*([^\r\n]*(?:\r?\n\s+[^\r\n:]+)*)')).Groups[1].Value -split '\s+' | Where-Object { $_ -ne '' }
    if (-not ($hw -contains '-mcpu=v11.0')) { throw "unexpected BSP cflags: $hw" }
    # -DSDT: the BSP drivers are built for the system-device-tree flow (base-address APIs).
    $mbflags = ($hw | Where-Object { $_ -ne '-mno-xl-soft-div' }) + @('-mno-xl-soft-div', '-DSDT')

    # 3. Linker script from the install template.
    $ld = Get-Content -LiteralPath $LdTmpl -Raw
    $memory = @"
MEMORY
{
   lmb_bram : ORIGIN = 0x50, LENGTH = 0x7FFB0
   axi_bram : ORIGIN = 0xC0000000, LENGTH = 0x20000
}
"@
    $ld = $ld.Replace('@STACK_SIZE@', '0x2000').Replace('@HEAP_SIZE@', '0x800').Replace('@MEMORY_SECTION@', $memory)
    $ld = $ld.Replace('@V_RESET@', '0x0').Replace('@V_EXCEPTION@', '0x8').Replace('@V_INTERRUPT@', '0x10').Replace('@V_HWEXCEPTION@', '0x20')
    $ld = $ld.Replace('@CODE@', 'lmb_bram').Replace('@DATA@', 'lmb_bram')
    $axi = @"
/* RTLNet: DMA frame buffers in the AXI BRAM (rtlnet_lwip_netif.c), never loaded. */
.axi_bram (NOLOAD) : {
   . = ALIGN(64);
   __axi_bram_start = .;
   *(.axi_bram)
   *(.axi_bram.*)
   __axi_bram_end = .;
} > axi_bram

_end = .;
"@
    if ($ld -notmatch '(?m)^_end = \.;') { throw "linker template changed: no '_end = .;' line" }
    $ld = [regex]::Replace($ld, '(?m)^_end = \.;', $axi.Replace('$', '$$'))
    $ldFile = Join-Path $Out 'lscript.ld'
    Set-Content -LiteralPath $ldFile -Value $ld -Encoding ascii

    # 4. Compile.
    $objDir = Join-Path $Out 'obj'
    if (Test-Path -LiteralPath $objDir) { Remove-Item -Recurse -Force -LiteralPath $objDir }
    New-Item -ItemType Directory -Force -Path $objDir | Out-Null
    $lwipInc = @("-I$Fw/src/lwip", '-isystem', "$LwipDir/src/include", '-isystem', "$LwipDir/contrib/ports/xilinx/include")
    $sysInc  = @('-isystem', $bspInc, "-specs=$bspSpec")
    # -O2 on the frame path (netif, lwIP glue, TCP echo, lwIP), -Os elsewhere (CLI, drivers).
    $cflags  = $common + @('-g', '-ffunction-sections', '-fdata-sections')
    $fastSrc = @('rtlnet_lwip_netif', 'rtlnet_lwip', 'rtlnet_tcp_echo', 'rtlnet_tcp_iperf')
    $objs = @()
    $fwSrcs = @(
        'src/main.c', 'src/rtlnet_platform.c', 'src/rtlnet_board.c', 'src/rtlnet_fmt.c', 'src/rtlnet_netmgr.c',
        'src/rtlnet_cpupath.c', 'src/lwip/rtlnet_lwip.c', 'src/lwip/rtlnet_lwip_netif.c', 'src/lwip/rtlnet_tcp_echo.c',
        'src/lwip/rtlnet_tcp_iperf.c',
        'cli/menu.c', 'cli/menu_table.c', 'cli/cli_commands.c'
    ) | ForEach-Object { "$Fw/$_" }
    foreach ($s in ($fwSrcs + ($drvSrcs | ForEach-Object { "$Repo/$_" }))) {
        $o = Join-Path $objDir (([System.IO.Path]::GetFileNameWithoutExtension($s)) + '.o')
        $opt = $(if ($fastSrc -contains [System.IO.Path]::GetFileNameWithoutExtension($s)) { '-O2' } else { '-Os' })
        Invoke-Step $MbGcc ($mbflags + $cflags + @($opt) + $inc + $lwipInc + $sysInc + @('-c', $s, '-o', $o))
        $objs += $o
    }
    # lwIP core: third-party sources, compiled in place with their own warning level.
    $lwipSrcs = @('core/init.c', 'core/def.c', 'core/inet_chksum.c', 'core/ip.c', 'core/mem.c', 'core/memp.c',
                  'core/netif.c', 'core/pbuf.c', 'core/stats.c', 'core/sys.c', 'core/tcp.c', 'core/tcp_in.c',
                  'core/tcp_out.c', 'core/timeouts.c', 'core/udp.c', 'core/raw.c',
                  'core/ipv4/etharp.c', 'core/ipv4/icmp.c', 'core/ipv4/ip4.c', 'core/ipv4/ip4_addr.c',
                  'core/ipv4/ip4_frag.c', 'netif/ethernet.c', 'apps/lwiperf/lwiperf.c')
    $lwipFlags = @('-std=gnu11', '-O2', '-g', '-ffunction-sections', '-fdata-sections', '-w')
    foreach ($s in $lwipSrcs) {
        $o = Join-Path $objDir ('lwip_' + ($s -replace '[/\\]', '_') -replace '\.c$', '.o')
        Invoke-Step $MbGcc ($mbflags + $lwipFlags + $lwipInc + $sysInc + @('-c', "$LwipDir/src/$s", '-o', $o))
        $objs += $o
    }

    # 5. Link with the BSP start-up and libraries.
    $elf = Join-Path $Out 'firmware.elf'
    Invoke-Step $MbGcc ($mbflags + @("-specs=$bspSpec", "-T$ldFile", '-Wl,--gc-sections', "-Wl,-Map=$Out/firmware.map",
        "-L$bspLib", '-o', $elf) + $objs + @('-Wl,--start-group', '-lxil', '-lxilstandalone', '-lxiltimer', '-lgcc', '-lc',
        '-Wl,--end-group'))
    & $MbSize $elf
    Write-Output "RTLNET_FW: PASS $elf"
}

# Desktop harness (host gcc): the same engine, callbacks, network manager and
# board layer against a register model; lwIP replaced by host/host_lwip_stub.c.
if ($HostHarness -or $Demo) {
    $hsrcs = @('host/main.c', 'host/host_platform.c', 'host/host_lwip_stub.c', 'src/rtlnet_board.c', 'src/rtlnet_fmt.c',
               'src/rtlnet_netmgr.c', 'src/rtlnet_cpupath.c', 'cli/menu.c', 'cli/menu_table.c', 'cli/cli_commands.c') |
             ForEach-Object { "$Fw/$_" }
    $exe = Join-Path $Out 'menu.exe'
    Invoke-Step 'gcc' ($common + @('-O2', '-DRTLNET_HOST_TEST', "-I$Fw/host") + $inc + $hsrcs +
        ($drvSrcs | ForEach-Object { "$Repo/$_" }) + @('-o', $exe))
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
