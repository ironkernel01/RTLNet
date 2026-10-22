<#
-------------------------------------------------------------------------------
File: rtlnet_vivado.ps1
Purpose: run one Vivado 2025.2 batch job with a machine-wide concurrency limit,
  so parallel work in several checkouts / git worktrees never runs more Vivado
  processes than the workstation's memory holds.
Overview:
  * Slots: %LOCALAPPDATA%/RTLNet/vivado_slot<N>.lock, delete-on-close, N in
    1..MaxSlots (default 2). The job waits for a free slot; a crashed holder
    releases its slot automatically when its process ends.
  * Runs vivado.bat -mode batch -nojournal -log <Log> -source <Tcl>
    -tclargs <TclArgs...> from <WorkDir> (default: the log's directory),
    passing arguments directly (no cmd.exe re-parsing, so NAME=VALUE survives).
  * Exit code: Vivado's exit code (the Tcl scripts define their gates).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_vivado.ps1 `
    -Tcl scripts/rtlnet_synth_check.tcl -Log .sim/synth/mac.log `
    -TclArgs rtlnet_eth_mac,cores/rtlnet_eth_mac/hdl/rtlnet_eth_mac.f,xc7a200tsbg484-1
Revision: 10-22-2026
  * 10-22-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Tcl,
    [Parameter(Mandatory = $true)][string]$Log,
    [string[]]$TclArgs = @(),
    [string]$WorkDir = '',
    [int]$MaxSlots = 2,
    [int]$WaitSeconds = 14400
)
$ErrorActionPreference = 'Stop'
$Repo    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Vivado  = 'C:/Xilinx/2025.2/Vivado/bin/vivado.bat'
$Shared  = Join-Path $env:LOCALAPPDATA 'RTLNet'
New-Item -ItemType Directory -Force -Path $Shared | Out-Null

$tclPath = if ([System.IO.Path]::IsPathRooted($Tcl)) { $Tcl } else { Join-Path $Repo $Tcl }
$logPath = if ([System.IO.Path]::IsPathRooted($Log)) { $Log } else { Join-Path $Repo $Log }
$logDir  = Split-Path -Parent $logPath
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
if (-not $WorkDir) { $WorkDir = $logDir }

# Acquire a slot.
$slot = $null
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ($null -eq $slot) {
    for ($n = 1; $n -le $MaxSlots -and $null -eq $slot; $n++) {
        try {
            $slot = [System.IO.FileStream]::new((Join-Path $Shared "vivado_slot$n.lock"),
                [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read,
                4096, [System.IO.FileOptions]::DeleteOnClose)
            $b = [System.Text.Encoding]::ASCII.GetBytes("pid=$PID tcl=$Tcl`r`n"); $slot.Write($b, 0, $b.Length); $slot.Flush()
        } catch [System.IO.IOException] { $slot = $null }
    }
    if ($null -eq $slot) {
        if ((Get-Date) -gt $deadline) { Write-Output "RTLNET_VIVADO: FAIL no free Vivado slot"; exit 1 }
        Start-Sleep -Seconds 10
    }
}
try {
    $argList = @('-mode', 'batch', '-nojournal', '-log', ($logPath -replace '\\', '/'), '-source', ($tclPath -replace '\\', '/'))
    if ($TclArgs.Count -gt 0) { $argList += '-tclargs'; $argList += $TclArgs }
    Push-Location $WorkDir
    try {
        & $Vivado @argList | Out-Null
        $rc = $LASTEXITCODE
    } finally { Pop-Location }
    Write-Output ("RTLNET_VIVADO: exit {0} log {1}" -f $rc, $logPath)
    exit $rc
} finally {
    $slot.Dispose()
}
