<#
Purpose: run the board's build-gate policy checks without Vivado or hardware.
Overview: source-closure and module-boundary preflight, deviation/vendor-review policy, publication flow mocks,
  implementation gates and camera IP staging; each check is self-contained (temporary folders, committed fixtures)
  and the IP staging and D-PHY source checks report SKIPPED when the third-party Digilent folder is absent.
Revision: 11-15-2026. Own-receiver wrapper and source closure checks.
#>
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo = (Resolve-Path (Join-Path $Board '..\..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Py = Resolve-RtlnetPython
foreach ($Check in 'check_baseline_sources.py', 'check_camera_deviation.py', 'check_camera_export.py',
                   'check_camera_implementation.py', 'check_camera_preparation.py') {
    $Out = & $Py -I (Join-Path $PSScriptRoot $Check) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Out | Select-Object -Last 12 | ForEach-Object { Write-Output "$_" }
        throw "board gate check failed: $Check"
    }
}
# Own-receiver variant: the generated wrapper is current and its source closure (including the receiver core) resolves.
foreach ($Own in @(@('rtlnet_generate_own_video.py', '--check'), @('check_baseline_sources.py', '--receiver', 'own'))) {
    $Out = & $Py -I (Join-Path $PSScriptRoot $Own[0]) @($Own | Select-Object -Skip 1) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Out | Select-Object -Last 12 | ForEach-Object { Write-Output "$_" }
        throw "board gate check failed: $($Own -join ' ')"
    }
}
Write-Output 'RTLNET_ZYBO_GATES: PASS source closure, deviation and vendor-review policy, publication flow, implementation gates, IP staging, own-receiver wrapper and closure'
