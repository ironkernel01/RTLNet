<#
-------------------------------------------------------------------------------
File: h264_driver_test.ps1
Purpose: build and run the host unit tests of the rtlnet_h264_enc driver (test_rtlnet_h264_enc_driver.c: the register driver, and
  test_rtlnet_h264_enc_ctl.c: the control layer with both notification modes against a functional core model) and of the rate
  controller (test_rtlnet_ratectl.c) with the host gcc from rtlnet_tools.ps1; prints the DRIVER TEST, CTL TEST and RATECTL_TEST
  lines and exits 0 when all pass. The control layer test is also built with -DINJECT_FAILURE: it must report CTL TEST FAIL (negative control).
  * Phase 2c-1 fields covered by the test: PIC_CFG bit 1 (start_picture_ex), REF_Y_BASE / REF_U_BASE with their alignment rules,
    next_frame_num (wrap), the two-buffer helper, VERSION 0x11102C02.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_driver_test.ps1
Revision: 11-12-2026
  * 11-12-2026: the control layer test (both notification modes), its negative control, and the rate controller test (moved with the controller).
  * 11-09-2026: initial version.
  * 11-10-2026: the test covers the P picture fields of the driver.
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Cc = Resolve-RtlnetHostCc
$env:PATH = "$(Split-Path -Parent $Cc);$env:PATH"
$exe = Join-Path (Get-RtlnetToolDir 'h264_enc') 'test_rtlnet_h264_enc_driver.exe'
& $Cc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST "-I$Repo/cores/rtlnet_common/driver" "-I$Repo/cores/rtlnet_h264_enc/driver" `
    "$Repo/cores/rtlnet_h264_enc/driver/rtlnet_h264_enc.c" "$Repo/cores/rtlnet_h264_enc/testbench/test_rtlnet_h264_enc_driver.c" -o $exe
if ($LASTEXITCODE -ne 0) { Write-Output 'DRIVER TEST FAIL: rtlnet_h264_enc build'; exit 1 }
$out = & $exe
$out | Select-Object -Last 1 | Write-Output
if ($LASTEXITCODE -ne 0) { exit 1 }

# Control layer: interrupt and polled completion against the core model, plus the negative control.
$drv = "$Repo/cores/rtlnet_h264_enc/driver"
$ctlSrc = @("$drv/rtlnet_h264_enc.c", "$drv/rtlnet_h264_enc_ctl.c", "$Repo/cores/rtlnet_h264_enc/testbench/test_rtlnet_h264_enc_ctl.c")
$ctlInc = @("-I$Repo/cores/rtlnet_common/driver", "-I$drv")
$exe2 = Join-Path (Get-RtlnetToolDir 'h264_enc') 'test_rtlnet_h264_enc_ctl.exe'
& $Cc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST @ctlInc @ctlSrc -o $exe2
if ($LASTEXITCODE -ne 0) { Write-Output 'CTL TEST FAIL: rtlnet_h264_enc_ctl build'; exit 1 }
$out2 = & $exe2
if ($LASTEXITCODE -ne 0) { $out2 | Write-Output } else { $out2 | Select-Object -Last 1 | Write-Output }
if ($LASTEXITCODE -ne 0) { exit 1 }
$exe3 = Join-Path (Get-RtlnetToolDir 'h264_enc') 'test_rtlnet_h264_enc_ctl_neg.exe'
& $Cc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -DINJECT_FAILURE @ctlInc @ctlSrc -o $exe3
if ($LASTEXITCODE -ne 0) { Write-Output 'CTL TEST FAIL: negative control build'; exit 1 }
$out3 = & $exe3
if (($LASTEXITCODE -eq 0) -or (-not ($out3 | Select-Object -Last 1) -or (($out3 | Select-Object -Last 1) -notmatch '^CTL TEST FAIL')) ) {
    Write-Output 'CTL TEST FAIL: the negative control did not report a failure'; exit 1 }
Write-Output 'CTL TEST negative control: reported CTL TEST FAIL as required'

# Rate controller (pure C, synthetic encoder model).
$exe4 = Join-Path (Get-RtlnetToolDir 'h264_enc') 'test_rtlnet_ratectl.exe'
& $Cc -std=c11 -Wall -Wextra -Werror -O2 "-I$drv" "$Repo/cores/rtlnet_h264_enc/testbench/test_rtlnet_ratectl.c" "$drv/rtlnet_ratectl.c" -lm -o $exe4
if ($LASTEXITCODE -ne 0) { Write-Output 'RATECTL_TEST FAIL: build'; exit 1 }
$out4 = & $exe4
$out4 | Select-Object -Last 1 | Write-Output
if ($LASTEXITCODE -ne 0) { exit 1 }
exit 0
