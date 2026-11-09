<#
-------------------------------------------------------------------------------
File: build.ps1
Purpose: build the RTLNet MicroBlaze V firmware in one command from a clean
  checkout: standalone BSP generated from the hardware export (XSA) by the
  Vitis tools of the AMD install, lwIP and the RTLNet core drivers compiled in
  place, the firmware linked into build/firmware.elf; and the CLI desktop
  harness (host gcc) into build/menu.exe.
Overview:
  1. cli/check_menu.py: the generated CLI tables match cli/cli_commands.txt.
  2. BSP (skipped when build/ws is newer than the XSA, or with -NoFirmware):
     `vitis -s bsp/rtlnet_bsp.py <xsa> build/ws` creates the platform
     component from the XSA (standalone OS on the MicroBlaze V microblaze_0, console
     axi_uartlite_0) and builds it: build/ws/plt/microblaze_0/dom/bsp/{include,
     lib} (libxil.a, libxilstandalone.a, libxiltimer.a), Xilinx.spec.
     Vivado/bin goes on PATH first (the Vitis server runs sdtgen and lopper
     from there).
  3. Linker script build/lscript.ld generated from the install's MicroBlaze V
     template (Vitis/data/embeddedsw/scripts/linker_files/lscript_mb_riscv.ld.in):
     boot code at address 0, code, data, heap and stack in the LMB BRAM, plus the NOLOAD
     section .axi_bram in the AXI BRAM for the DMA frame buffers.
  4. Compile: firmware (src, cli) and the RTLNet core drivers
     (cores/<core>/driver, in place) with -std=c11 -Wall -Wextra -Werror
     -pedantic; lwIP 2.2.0 core, IPv4 and Ethernet sources from the install
     (Vitis/data/embeddedsw/ThirdParty/sw_services/lwip220_v1_3/src/lwip-2.2.0),
     in place with src/lwip/lwipopts.h. The iperf server is the project copy
     src/lwip/rtlnet_lwiperf.c (a modified copy of the install's lwiperf.c, the
     one exception to "nothing is copied from the install"); the install's
     apps/lwiperf/lwiperf.c is not compiled.
  * Compiler: the RISC-V GNU toolchain of the install (riscv64-unknown-elf-gcc,
    Resolve-RtlnetXilinx .RvBin) with the -march/-mabi of the BSP (cflags.yaml);
    the script requires an rv32 -march with the M, C and Zicsr extensions.
  5. Link with the BSP start-up (crt0/crtinit through Xilinx.spec) and
     libraries; print the section sizes.
  * -HostHarness: also build build/menu.exe (stdin/stdout harness, register
    model, host/host_lwip_stub.c in place of lwIP). -Demo: build the harness
    and run its scripted --demo session; the exit code follows the anchored
    TEST PASS / TEST FAIL line. -LwipTest: build and run the desktop loopback
    test of the iperf server (test/lwiperf_loopback: lwIP core from the install,
    src/lwip/rtlnet_lwiperf.c and a scripted iperf 2 client in one host process
    over lwIP's 127.0.0.1 interface); the exit code follows the anchored
    LWIPERF_LOOPBACK: PASS / FAIL line. -NetifTest: build and run, for each combination of
    the zero-copy options (RTLNET_NETIF_ZERO_COPY_RX / _TX = 1/1, 0/0, 1/0, 0/1), the desktop
    test of the DMA netif (test/netif_host: rtlnet_lwip_netif.c, rtlnet_offload.c and the core
    drivers on lwIP from the install, a mock of the AXI DMA driver and a register model of the
    protocol wrapper and the checksum offload core); each run ends with NETIF_HOST: PASS / FAIL.
    -NoFirmware: harness only. -Bsp: regenerate
    the BSP even when it is up to date. -Xsa: another hardware export. -Define:
    extra -D macros for the firmware and lwIP compilation (the zero-copy options of
    src/lwip/lwipopts.h: RTLNET_NETIF_ZERO_COPY_RX=0, RTLNET_NETIF_ZERO_COPY_TX=0).
  * Exit code 0 only when every requested step succeeded; prints
    RTLNET_FW: PASS <elf>.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File microblaze/firmware/build.ps1 `
    [-Xsa <xsa>] [-Bsp] [-HostHarness] [-Demo] [-LwipTest] [-NetifTest] [-NoFirmware] [-Define NAME=VALUE,...]
Revision: 11-09-2026
  * 10-22-2026: initial version.
  * 10-22-2026: generated standalone BSP, lwIP, BSP linker conventions;
    hand-written start-up, UART, timer and string files removed.
  * 10-22-2026: lwIP glue and applications in src/lwip; iperf server from the
    project copy src/lwip/rtlnet_lwiperf.c instead of the install's lwiperf.c.
  * 11-09-2026: MicroBlaze V: RISC-V toolchain and flags from the BSP, RISC-V linker template.
  * 11-09-2026: link with --no-warn-rwx-segments (one RWX LMB segment is intended).
-------------------------------------------------------------------------------
#>
param(
    [string]$Xsa = '',
    [switch]$Bsp,
    [switch]$HostHarness,
    [switch]$Demo,
    [switch]$LwipTest,
    [switch]$NetifTest,
    [switch]$NoFirmware,
    [string[]]$Define = @()
)
$ErrorActionPreference = 'Stop'
# powershell -File delivers '-Define A,B' as one string: split every entry on commas.
$Define = @($Define | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
$Fw      = $PSScriptRoot
$Repo    = (Resolve-Path (Join-Path $Fw '..\..')).Path
$Out     = Join-Path $Fw 'build'
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
$Xilinx  = (Resolve-RtlnetXilinx).Root
# Host gcc (desktop harnesses); its bin on PATH for the MinGW runtime DLLs of the built tests.
$HostCc  = try { Resolve-RtlnetHostCc } catch { 'gcc' }
if ($HostCc -ne 'gcc') { $env:PATH = (Split-Path -Parent $HostCc) + ';' + $env:PATH }
$RvBin   = (Resolve-RtlnetXilinx).RvBin
$MbGcc   = Join-Path $RvBin 'riscv64-unknown-elf-gcc.exe'
$MbSize  = Join-Path $RvBin 'riscv64-unknown-elf-size.exe'
$Vitis   = "$Xilinx/Vitis/bin/vitis.bat"
$Esw     = "$Xilinx/Vitis/data/embeddedsw"
$LwipDir = "$Esw/ThirdParty/sw_services/lwip220_v1_3/src/lwip-2.2.0"
$LdTmpl  = "$Esw/scripts/linker_files/lscript_mb_riscv.ld.in"
if (-not $Xsa) { $Xsa = Join-Path $Repo 'boards\nexys_video\build\rtlnet_nexys_video.xsa' }
$Ws      = Join-Path $Out 'ws'
$BspDir  = Join-Path $Ws 'plt\microblaze_0\dom\bsp'
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Invoke-Step([string]$exe, [string[]]$argv) {
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { throw "failed ($LASTEXITCODE): $([System.IO.Path]::GetFileName($exe)) ... $($argv[-1])" }
}
function Fwd([string]$p) { return ($p -replace '\\', '/') }

# Core drivers (cores/<core>/driver): the only code that touches each core.
$drvCores = @('rtlnet_eth_mac', 'rtlnet_mdio', 'rtlnet_eth_protocol', 'rtlnet_arp', 'rtlnet_icmp',
              'rtlnet_dhcp', 'rtlnet_iperf', 'rtlnet_udp_socket', 'rtlnet_udp_echo', 'rtlnet_classifier',
              'rtlnet_tcp_offload')
$drvSrcs = @(
    'cores/rtlnet_eth_mac/driver/rtlnet_eth_mac.c', 'cores/rtlnet_mdio/driver/rtlnet_mdio.c',
    'cores/rtlnet_mdio/driver/rtlnet_phy_rtl8211e.c', 'cores/rtlnet_eth_protocol/driver/rtlnet_eth_protocol.c',
    'cores/rtlnet_arp/driver/rtlnet_arp.c', 'cores/rtlnet_icmp/driver/rtlnet_icmp.c',
    'cores/rtlnet_dhcp/driver/rtlnet_dhcp.c', 'cores/rtlnet_iperf/driver/rtlnet_iperf.c',
    'cores/rtlnet_udp_socket/driver/rtlnet_udp_socket.c', 'cores/rtlnet_udp_echo/driver/rtlnet_udp_echo.c',
    'cores/rtlnet_classifier/driver/rtlnet_classifier.c', 'cores/rtlnet_tcp_offload/driver/rtlnet_tcp_offload.c'
) | Where-Object { Test-Path -LiteralPath (Join-Path $Repo $_) }
$inc = @(
    "-I$Fw/src", "-I$Fw/src/lwip", "-I$Fw/cli",
    "-I$Repo/cores/rtlnet_common/driver",
    "-I$Repo/microblaze/driver"
) + ($drvCores | Where-Object { Test-Path -LiteralPath (Join-Path $Repo "cores/$_/driver") } |
     ForEach-Object { "-I$Repo/cores/$_/driver" })
$common = @('-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic') + ($Define | ForEach-Object { "-D$_" })

# lwIP core, IPv4 and Ethernet sources compiled from the install (firmware and loopback test).
$lwipSrcs = @('core/init.c', 'core/def.c', 'core/inet_chksum.c', 'core/ip.c', 'core/mem.c', 'core/memp.c',
              'core/netif.c', 'core/pbuf.c', 'core/stats.c', 'core/sys.c', 'core/tcp.c', 'core/tcp_in.c',
              'core/tcp_out.c', 'core/timeouts.c', 'core/udp.c', 'core/raw.c',
              'core/ipv4/etharp.c', 'core/ipv4/icmp.c', 'core/ipv4/ip4.c', 'core/ipv4/ip4_addr.c',
              'core/ipv4/ip4_frag.c', 'netif/ethernet.c')

# 1. The generated CLI tables must match the command file.
Invoke-Step (Resolve-RtlnetPython) @("$Fw/cli/check_menu.py")

if (-not $NoFirmware) {
    # 2. BSP from the XSA.
    if (-not (Test-Path -LiteralPath $Xsa)) { throw "no hardware export at $Xsa (build the bitstream first: boards/nexys_video/scripts/build.ps1)" }
    $Xsa = (Resolve-Path -LiteralPath $Xsa).Path   # Vitis runs from $Out: a relative -Xsa must not resolve there
    $marker = Join-Path $Out 'bsp.stamp'
    $fresh = (Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath (Join-Path $BspDir 'lib\libxil.a')) -and
             ((Get-Item -LiteralPath $marker).LastWriteTime -ge (Get-Item -LiteralPath $Xsa).LastWriteTime) -and
             ((Get-Content -LiteralPath $marker -Raw).Trim() -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $Xsa).Hash)
    if ($Bsp -or -not $fresh) {
        # Windows tools of the BSP build fail on object paths above about 250 characters.
        $deepest = (Fwd $BspDir) + '/libsrc/build_configs/gen_bsp/libsrc/standalone/src/CMakeFiles/xilstandalone.dir/riscv/riscv_invalidate_icache_range.S.obj.d'
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
    # The processor is MicroBlaze V: rv32 with M and C (the BSP's -march names the extensions of the
    # CPU configuration, e.g. rv32imcb_zicsr_zifencei) and the ilp32 ABI.
    $march = ($hw | Where-Object { $_ -like '-march=*' } | Select-Object -First 1)
    $mabi  = ($hw | Where-Object { $_ -like '-mabi=*' } | Select-Object -First 1)
    if (-not $march -or $march -notmatch '^-march=rv32i[a-z]*m[a-z]*c' -or $march -notmatch 'zicsr' -or $mabi -ne '-mabi=ilp32') {
        throw "unexpected BSP cflags (expected rv32 with M, C, Zicsr and ilp32): $hw"
    }
    # -DSDT: the BSP drivers are built for the system-device-tree flow (base-address APIs).
    $mbflags = $hw + @('-DSDT')

    # 3. Linker script from the install template.
    $ld = Get-Content -LiteralPath $LdTmpl -Raw
    $memory = @"
MEMORY
{
   lmb_bram : ORIGIN = 0x0, LENGTH = 0x80000
   axi_bram : ORIGIN = 0xC0000000, LENGTH = 0x20000
}
"@
    $ld = $ld.Replace('@STACK_SIZE@', '0x2000').Replace('@HEAP_SIZE@', '0x800').Replace('@MEMORY_SECTION@', $memory)
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
"@
    if ($ld -notmatch '(?m)^_end = \.;') { throw "linker template changed: no '_end = .;' line" }
    # _end stays where the template puts it (end of the LMB image): the RISC-V start-up clears
    # memory from the start of .bss to _end, so _end must not lie past the AXI BRAM section.
    $ld = [regex]::Replace($ld, '(?m)^_end = \.;', ('_end = .;' + "`n`n" + $axi).Replace('$', '$$'))
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
    $fastSrc = @('rtlnet_lwip_netif', 'rtlnet_lwip', 'rtlnet_tcp_echo', 'rtlnet_tcp_iperf', 'rtlnet_lwiperf', 'rtlnet_offload')
    $objs = @()
    $fwSrcs = @(
        'src/main.c', 'src/rtlnet_platform.c', 'src/rtlnet_board.c', 'src/rtlnet_fmt.c', 'src/rtlnet_netmgr.c',
        'src/rtlnet_cpupath.c', 'src/rtlnet_offload.c', 'src/lwip/rtlnet_lwip.c', 'src/lwip/rtlnet_lwip_netif.c', 'src/lwip/rtlnet_tcp_echo.c',
        'src/lwip/rtlnet_tcp_iperf.c', 'src/lwip/rtlnet_lwiperf.c',
        'cli/menu.c', 'cli/menu_table.c', 'cli/cli_commands.c'
    ) | ForEach-Object { "$Fw/$_" }
    foreach ($s in ($fwSrcs + ($drvSrcs | ForEach-Object { "$Repo/$_" }))) {
        $o = Join-Path $objDir (([System.IO.Path]::GetFileNameWithoutExtension($s)) + '.o')
        $opt = $(if ($fastSrc -contains [System.IO.Path]::GetFileNameWithoutExtension($s)) { '-O2' } else { '-Os' })
        Invoke-Step $MbGcc ($mbflags + $cflags + @($opt) + $inc + $lwipInc + $sysInc + @('-c', $s, '-o', $o))
        $objs += $o
    }
    # lwIP core: third-party sources, compiled in place with their own warning level.
    $lwipFlags = @('-std=gnu11', '-O2', '-g', '-ffunction-sections', '-fdata-sections', '-w') + ($Define | ForEach-Object { "-D$_" })
    foreach ($s in $lwipSrcs) {
        $o = Join-Path $objDir ('lwip_' + ($s -replace '[/\\]', '_') -replace '\.c$', '.o')
        Invoke-Step $MbGcc ($mbflags + $lwipFlags + $lwipInc + $sysInc + @('-c', "$LwipDir/src/$s", '-o', $o))
        $objs += $o
    }

    # 5. Link with the BSP start-up and libraries. One LMB holds code and data, so the single RWX
    # segment is intended: --no-warn-rwx-segments silences the linker warning about it.
    $elf = Join-Path $Out 'firmware.elf'
    Invoke-Step $MbGcc ($mbflags + @("-specs=$bspSpec", "-T$ldFile", '-Wl,--gc-sections', '-Wl,--no-warn-rwx-segments', "-Wl,-Map=$Out/firmware.map",
        "-L$bspLib", '-o', $elf) + $objs + @('-Wl,--start-group', '-lxil', '-lxilstandalone', '-lxiltimer', '-lgcc', '-lc',
        '-Wl,--end-group'))
    & $MbSize $elf
    Write-Output "RTLNET_FW: PASS $elf"
}

# Desktop harness (host gcc): the same engine, callbacks, network manager and
# board layer against a register model; lwIP replaced by host/host_lwip_stub.c.
if ($HostHarness -or $Demo) {
    $hsrcs = @('host/main.c', 'host/host_platform.c', 'host/host_lwip_stub.c', 'src/rtlnet_board.c', 'src/rtlnet_fmt.c',
               'src/rtlnet_netmgr.c', 'src/rtlnet_cpupath.c', 'src/rtlnet_offload.c', 'cli/menu.c', 'cli/menu_table.c',
               'cli/cli_commands.c') |
             ForEach-Object { "$Fw/$_" }
    $exe = Join-Path $Out 'menu.exe'
    Invoke-Step $HostCc ($common + @('-O2', '-DRTLNET_HOST_TEST', "-I$Fw/host") + $inc + $hsrcs +
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

# Desktop loopback test of rtlnet_lwiperf (host gcc): one lwIP instance holds the
# iperf server and a scripted client that sends the captured iperf 2.2.2 headers.
if ($LwipTest) {
    $lt   = Join-Path $Out 'lwtest'
    if (Test-Path -LiteralPath $lt) { Remove-Item -Recurse -Force -LiteralPath $lt }
    New-Item -ItemType Directory -Force -Path $lt | Out-Null
    $ltInc = @("-I$Fw/test/lwiperf_loopback", "-I$Fw/src/lwip", '-isystem', "$LwipDir/src/include", '-isystem', "$LwipDir/contrib/ports/xilinx/include")
    $ltObjs = @()
    foreach ($s in $lwipSrcs) {
        $o = Join-Path $lt (($s -replace '[/\\]', '_') -replace '\.c$', '.o')
        Invoke-Step $HostCc (@('-std=gnu11', '-O1', '-g', '-w') + $ltInc + @('-c', "$LwipDir/src/$s", '-o', $o))
        $ltObjs += $o
    }
    foreach ($s in @("$Fw/src/lwip/rtlnet_lwiperf.c", "$Fw/test/lwiperf_loopback/lwiperf_loopback_test.c")) {
        $o = Join-Path $lt (([System.IO.Path]::GetFileNameWithoutExtension($s)) + '.o')
        Invoke-Step $HostCc (@('-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror') + $ltInc + @('-c', $s, '-o', $o))
        $ltObjs += $o
    }
    $ltExe = Join-Path $Out 'lwiperf_loopback.exe'
    Invoke-Step $HostCc (@('-o', $ltExe) + $ltObjs)
    $ltLog = & $ltExe
    $ltRc = $LASTEXITCODE
    $ltLog | ForEach-Object { Write-Output $_ }
    $ltVerdict = $ltLog | Where-Object { $_ -match '^LWIPERF_LOOPBACK: (PASS|FAIL)' } | Select-Object -Last 1
    if ($ltRc -ne 0 -or -not $ltVerdict -or $ltVerdict -notmatch '^LWIPERF_LOOPBACK: PASS') {
        throw "lwiperf loopback test did not pass"
    }
}

# Desktop test of the DMA netif (host gcc) for every combination of the zero-copy options.
if ($NetifTest) {
    $nt = Join-Path $Out 'nettest'
    $ntSrcs = @("$Fw/src/lwip/rtlnet_lwip_netif.c", "$Fw/src/rtlnet_offload.c", "$Fw/src/rtlnet_fmt.c",
                "$Repo/cores/rtlnet_eth_protocol/driver/rtlnet_eth_protocol.c",
                "$Repo/cores/rtlnet_tcp_offload/driver/rtlnet_tcp_offload.c", "$Fw/test/netif_host/netif_host_test.c")
    foreach ($combo in @(@(1, 1), @(0, 0), @(1, 0), @(0, 1))) {
        if (Test-Path -LiteralPath $nt) { Remove-Item -Recurse -Force -LiteralPath $nt }
        New-Item -ItemType Directory -Force -Path $nt | Out-Null
        $zc = @("-DRTLNET_NETIF_ZERO_COPY_RX=$($combo[0])", "-DRTLNET_NETIF_ZERO_COPY_TX=$($combo[1])", '-DRTLNET_HOST_TEST')
        $ntInc = @("-I$Fw/test/netif_host", "-I$Fw/src", "-I$Fw/src/lwip", "-I$Repo/cores/rtlnet_common/driver",
                   "-I$Repo/microblaze/driver", "-I$Repo/cores/rtlnet_eth_protocol/driver", "-I$Repo/cores/rtlnet_classifier/driver",
                   "-I$Repo/cores/rtlnet_tcp_offload/driver", '-isystem', "$LwipDir/src/include", '-isystem', "$LwipDir/contrib/ports/xilinx/include")
        $ntObjs = @()
        foreach ($s in $lwipSrcs) {
            $o = Join-Path $nt (($s -replace '[/\\]', '_') -replace '\.c$', '.o')
            Invoke-Step $HostCc (@('-std=gnu11', '-O1', '-g', '-w') + $zc + $ntInc + @('-c', "$LwipDir/src/$s", '-o', $o))
            $ntObjs += $o
        }
        foreach ($s in $ntSrcs) {
            $o = Join-Path $nt (([System.IO.Path]::GetFileNameWithoutExtension($s)) + '.o')
            Invoke-Step $HostCc (@('-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror') + $zc + $ntInc + @('-c', $s, '-o', $o))
            $ntObjs += $o
        }
        $ntExe = Join-Path $Out 'netif_host.exe'
        Invoke-Step $HostCc (@('-o', $ntExe) + $ntObjs)
        $ntLog = & $ntExe
        $ntRc = $LASTEXITCODE
        $ntLog | ForEach-Object { Write-Output $_ }
        $ntVerdict = $ntLog | Where-Object { $_ -match '^NETIF_HOST: (PASS|FAIL)' } | Select-Object -Last 1
        if ($ntRc -ne 0 -or -not $ntVerdict -or $ntVerdict -notmatch '^NETIF_HOST: PASS') {
            throw "netif host test did not pass (zero-copy RX $($combo[0]), TX $($combo[1]))"
        }
    }
}
exit 0
