<#
-------------------------------------------------------------------------------
File: venc_irq_host_test.ps1
Purpose: build and run the host test of the encoder session in both notification modes (venc_irq_host_test.c) with the host C compiler found by
  Resolve-RtlnetHostCc: the positive run and the negative control (--neg). The test links the firmware's encoder session, the driver layer of
  cores/rtlnet_h264_enc, the picture queue, the multiplexer and the harness models (host/host_platform.c, host/host_h264_model.c).
  Exit code 0 when the positive run passes and the negative control fails as required.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_h264/firmware/test/venc_irq_host_test.ps1
Revision: 11-14-2026
  * 11-14-2026: moved to cpu/microblaze_v_h264/ (was microblaze/).
  * 11-12-2026: initial version.
  * 11-12-2026: the deblocking filter scenario (on and off between pictures, offsets, request kept across a restart, a core without the filter).
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Fw   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo = (Resolve-Path (Join-Path $Fw '..\..\..')).Path
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
$cc  = Resolve-RtlnetHostCc
$env:PATH = "$(Split-Path -Parent $cc);$env:PATH"
$out = Join-Path $Fw 'build\venc_irq_test.exe'
New-Item -ItemType Directory -Force -Path (Join-Path $Fw 'build') | Out-Null
$drvCores = @('rtlnet_eth_mac', 'rtlnet_mdio', 'rtlnet_eth_protocol', 'rtlnet_arp', 'rtlnet_icmp', 'rtlnet_dhcp', 'rtlnet_iperf', 'rtlnet_udp_socket',
              'rtlnet_udp_echo', 'rtlnet_classifier', 'rtlnet_tcp_offload', 'rtlnet_axi_arbiter', 'rtlnet_csi2_rx', 'rtlnet_vdma_s2mm', 'rtlnet_framebuf', 'rtlnet_h264_enc')
$inc = @("-I$Fw/src", "-I$Fw/src/lwip", "-I$Fw/src/video", "-I$Fw/cli", "-I$Fw/host", "-I$Repo/cores/rtlnet_common/driver", "-I$Repo/cpu/microblaze_v_h264/driver") +
       ($drvCores | Where-Object { Test-Path -LiteralPath (Join-Path $Repo "cores/$_/driver") } | ForEach-Object { "-I$Repo/cores/$_/driver" })
$srcs = @('test/venc_irq_host_test.c', 'host/host_platform.c', 'host/host_h264_model.c', 'host/host_lwip_stub.c', 'src/rtlnet_board.c', 'src/rtlnet_fmt.c',
          'src/rtlnet_netmgr.c', 'src/rtlnet_cpupath.c', 'src/rtlnet_offload.c', 'src/rtlnet_ddrtest.c', 'src/rtlnet_fbcrc.c', 'src/video/rtlnet_tsmux.c',
          'src/video/rtlnet_picq.c', 'src/video/rtlnet_muxjob.c', 'src/video/rtlnet_venc.c', 'cli/menu.c', 'cli/menu_table.c', 'cli/cli_commands.c') | ForEach-Object { "$Fw/$_" }
$drv = Get-ChildItem -Path ($drvCores | ForEach-Object { Join-Path $Repo "cores/$_/driver/*.c" }) -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName } |
       Where-Object { $_ -notmatch 'test' }
& $cc -std=c11 -Wall -Wextra -Werror -pedantic -O2 -DRTLNET_HOST_TEST @inc @srcs @drv -o $out
if ($LASTEXITCODE -ne 0) { Write-Output 'VENC_IRQ_TEST: FAIL build'; exit 1 }
$a = & $out
$ra = $LASTEXITCODE
$b = & $out --neg
$rb = $LASTEXITCODE
$a | Select-Object -Last 12 | Write-Output
$b | Select-Object -Last 2 | Write-Output
if ($ra -ne 0) { Write-Output 'VENC_IRQ_TEST: the positive run failed'; exit 1 }
if ($rb -eq 0) { Write-Output 'VENC_IRQ_TEST: the negative control did not fail'; exit 1 }
Write-Output 'VENC_IRQ_TEST: positive run passes, negative control fails as required'
exit 0
