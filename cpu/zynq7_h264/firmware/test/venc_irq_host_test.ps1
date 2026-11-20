<# Purpose: run the retained session IRQ/polled tests against ARM platform mocks.
Overview: uses copied source/models, no MicroBlaze CPU dependency at build time.
Revision: 11-14-2026. Initial ARM harness runner. #>
$ErrorActionPreference='Stop'
$fw=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repo=(Resolve-Path (Join-Path $fw '../../..')).Path
. (Join-Path $repo 'scripts/rtlnet_tools.ps1')
$cc=Resolve-RtlnetHostCc
$out=Join-Path $fw 'build'
New-Item -ItemType Directory -Force $out | Out-Null
$inc=@("-I$fw/src","-I$fw/src/video","-I$fw/src/drivers","-I$fw/src/lwip","-I$fw/test/host",
 "-I$repo/cores/rtlnet_common/driver","-I$repo/ip/rtlnet_csi2_rx/driver","-I$repo/cores/rtlnet_framebuf/driver","-I$repo/cores/rtlnet_vdma_s2mm/driver")
$src=@("$fw/test/venc_irq_host_test.c","$fw/test/host/rtlnet_host_video_model.c","$fw/test/host/rtlnet_host_udp_model.c",
 "$fw/test/host/host_h264_model.c","$fw/src/rtlnet_camera.c",
 "$repo/ip/rtlnet_csi2_rx/driver/rtlnet_csi2_rx.c","$repo/cores/rtlnet_framebuf/driver/rtlnet_framebuf.c","$repo/cores/rtlnet_vdma_s2mm/driver/rtlnet_vdma_s2mm.c")
$src+=@(Get-ChildItem "$fw/src/video/*.c","$fw/src/drivers/*.c" | ForEach-Object {$_.FullName})
& $cc -std=c11 -O2 -Wall -Wextra -Werror -pedantic -DRTLNET_HOST_TEST @inc @src -o "$out/rtlnet_venc_irq_test.exe"
if($LASTEXITCODE){throw 'session IRQ harness compile failed'}
$positive=& "$out/rtlnet_venc_irq_test.exe"
$code=$LASTEXITCODE
$positive | Select-Object -Last 10 | Write-Output
if($code){throw 'session IRQ positive failed'}
$negative=& "$out/rtlnet_venc_irq_test.exe" --neg
$code=$LASTEXITCODE
$negative | Select-Object -Last 2 | Write-Output
if($code -eq 0){throw 'session IRQ negative failed to fail'}
Write-Output 'RTLNET_ARM_VENC_IRQ: PASS retained session scenarios; negative control fails'
