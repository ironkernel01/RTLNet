<#
-------------------------------------------------------------------------------
File: csi2_rx_model.ps1
Purpose: run the Python reference model of the camera receiver video path (csi2_rx_model.py) with the Python of rtlnet_tools.ps1:
  the known-value self test of the model, then the check that the committed stimulus and expected-result files of the benches
  (csi2_rx_<set>_cfg/raw/exp.mem) equal what the model generates. -Write regenerates the files.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File csi2_rx_model.ps1 [-Write]
  The last line is "CSI2_RX_MODEL_XCHECK: PASS" (exit 0) or "CSI2_RX_MODEL_XCHECK: FAIL ..." (exit 1).
Revision: 11-15-2026
  * 11-15-2026: initial version.
-------------------------------------------------------------------------------
#>
param([switch]$Write)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$py = Resolve-RtlnetPython
$model = Join-Path $PSScriptRoot 'csi2_rx_model.py'
if ($Write) {
    & $py -I $model --write $PSScriptRoot
    if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_RX_MODEL_XCHECK: FAIL write'; exit 1 }
    Write-Output 'CSI2_RX_MODEL_XCHECK: PASS files written'
    exit 0
}
& $py -I $model --selftest
if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_RX_MODEL_XCHECK: FAIL self test'; exit 1 }
& $py -I $model --verify $PSScriptRoot
if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_RX_MODEL_XCHECK: FAIL files differ from the model'; exit 1 }
Write-Output 'CSI2_RX_MODEL_XCHECK: PASS'
exit 0
