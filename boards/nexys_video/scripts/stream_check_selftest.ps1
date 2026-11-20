<#
-------------------------------------------------------------------------------
File: stream_check_selftest.ps1
Purpose: host test of the pattern PSNR path of stream_check.py (the board stream checker): streams are built from the
  Python pattern model (ip/rtlnet_csi2_rx/testbench/pattern_model.py) through ffmpeg libx264, pictures are left out and
  k is resynced. Regression entry of boards/nexys_video/testbench/regression.txt (script: type, passes on exit code 0).
  Without ffmpeg (RTLNET_FFMPEG or PATH) the step prints SKIP and passes.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File stream_check_selftest.ps1
Revision: 11-13-2026
  * 11-13-2026: initial version (moved out of ip/rtlnet_csi2_rx/testbench/csi2_bars_model.ps1 -Verify).
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$py = Resolve-RtlnetPython
$ff = $null
try { $ff = (Resolve-RtlnetFfmpeg).Ffmpeg } catch { $ff = $null }
if (-not $ff) { Write-Output 'STREAM_CHECK_SELFTEST: SKIP (no ffmpeg)'; exit 0 }
$sc = & $py -I (Join-Path $PSScriptRoot 'stream_check.py') selftest $ff
$code = $LASTEXITCODE
$sc | Where-Object { $_ -like 'CHECK selftest*' } | Write-Output
if ($code -ne 0) { Write-Output 'STREAM_CHECK_SELFTEST: FAIL'; exit 1 }
Write-Output 'STREAM_CHECK_SELFTEST: PASS'
exit 0
