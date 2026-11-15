<#
Purpose: run the board's build-gate policy checks without Vivado or hardware.
Overview: source-closure and module-boundary preflight, deviation and reviewed-waiver policy, publication flow mocks and
  implementation gates; each check is self-contained (temporary folders) and runs the real scripts of the build.
Revision: 11-15-2026.
#>
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo = (Resolve-Path (Join-Path $Board '..\..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Py = Resolve-RtlnetPython
foreach ($Check in @(@('check_sources.py'), @('rtlnet_generate_video_wrapper.py', '--check'), @('check_camera_deviation.py'),
                     @('check_camera_export.py'), @('check_camera_implementation.py'))) {
    $Out = & $Py -I (Join-Path $PSScriptRoot $Check[0]) @($Check | Select-Object -Skip 1) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Out | Select-Object -Last 12 | ForEach-Object { Write-Output "$_" }
        throw "board gate check failed: $($Check -join ' ')"
    }
}
Write-Output 'RTLNET_ZYBO_GATES: PASS source closure and module boundary, deviation and reviewed-waiver policy, publication flow, build preflight, implementation gates'
