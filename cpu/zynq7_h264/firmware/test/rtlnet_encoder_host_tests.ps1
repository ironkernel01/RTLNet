<# Purpose: test the copied register/control drivers with the original host models.
Overview: generated devices only; no PS peripheral or hardware encode claim.
Revision: 11-14-2026. Keep applicable driver tests in the new CPU folder. #>
$ErrorActionPreference='Stop'
$fw=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repo=(Resolve-Path (Join-Path $fw '../../..')).Path
. (Join-Path $repo 'scripts/rtlnet_tools.ps1')
$cc=Resolve-RtlnetHostCc
$out=Join-Path $fw 'build'
New-Item -ItemType Directory -Force $out | Out-Null
$inc=@("-I$fw/src/drivers","-I$repo/cores/rtlnet_common/driver")
$drv="$fw/src/drivers/rtlnet_h264_enc.c"
& $cc -std=c11 -O2 -Wall -Wextra -Werror -DRTLNET_HOST_TEST @inc $drv "$fw/test/test_rtlnet_h264_enc_driver.c" -o "$out/rtlnet_enc_driver_test.exe"
if($LASTEXITCODE){throw 'register driver compile failed'}
& "$out/rtlnet_enc_driver_test.exe" | Select-Object -Last 1
if($LASTEXITCODE){throw 'register driver model failed'}
$src=@($drv,"$fw/src/drivers/rtlnet_h264_enc_ctl.c","$fw/test/test_rtlnet_h264_enc_ctl.c")
& $cc -std=c11 -O2 -Wall -Wextra -Werror -DRTLNET_HOST_TEST @inc @src -o "$out/rtlnet_enc_ctl_test.exe"
if($LASTEXITCODE){throw 'control driver compile failed'}
& "$out/rtlnet_enc_ctl_test.exe" | Select-Object -Last 1
if($LASTEXITCODE){throw 'control driver model failed'}
& $cc -std=c11 -O2 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -DINJECT_FAILURE @inc @src -o "$out/rtlnet_enc_ctl_neg.exe"
if($LASTEXITCODE){throw 'control negative compile failed'}
$neg=& "$out/rtlnet_enc_ctl_neg.exe"
$code=$LASTEXITCODE
$neg | Select-Object -Last 2 | Write-Output
if($code -eq 0 -or $neg[-1] -notmatch '^CTL TEST FAIL'){throw 'control negative failed to fail'}
Write-Output 'RTLNET_ARM_ENCODER_HOST: PASS register/control models and negative control'
