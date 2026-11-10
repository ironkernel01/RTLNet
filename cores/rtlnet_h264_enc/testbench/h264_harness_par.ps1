<#
-------------------------------------------------------------------------------
File: h264_harness_par.ps1
Purpose: run the configurations of h264_harness.ps1 in parallel (one harness process per configuration, at most -Jobs at a time)
  and report one verdict line per configuration; the long P-picture runs of phase 2c-1 use it.
Overview:
  * The configuration names come from `h264_harness.ps1 -ListConfigs -Config ...`. Each runs as its own process
    (`h264_harness.ps1 -Config <name> <passthrough switches>`), its output goes to <LogDir>/<Prefix>_<name>.log, and the verdict is
    the last TEST PASS / TEST FAIL line of that log. The SPS/PPS tool is built once before the processes start, so they do not race.
  * Prints `PAR <name>: PASS|FAIL (<seconds> s)` per configuration and `PAR RESULT: <passed> of <total> passed`; exits 0 only when
    every configuration passed. The full per-configuration logs stay in <LogDir>.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_harness_par.ps1 -Config p_* [-Jobs 4] [-Prefix p2c1] [-LogDir <dir>]
         [-Measure] [-Gap pct] [-Lat clocks] [-Inject] [-InjectBurst] [-InjectBurstRef] [-Pcm] [-NoPng]
Revision: 11-10-2026
  * 11-10-2026: initial version (phase 2c-1).
-------------------------------------------------------------------------------
#>
param(
    [string[]]$Config = @(),
    [int]$Jobs = 4,
    [string]$Prefix = 'par',
    [string]$LogDir = '',
    [switch]$Measure,
    [switch]$Inject,
    [switch]$InjectBurst,
    [switch]$InjectBurstRef,
    [switch]$Pcm,
    [switch]$NoPng,
    [int]$Gap = 20,
    [int]$Lat = 20
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
if ($LogDir -eq '') { $LogDir = Join-Path $Repo '.sim/logs' }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Harness = Join-Path $PSScriptRoot 'h264_harness.ps1'
$base = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Harness)
$cfgArg = ($Config | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' }) -join ','
$listArgs = @('-ListConfigs'); if ($cfgArg -ne '') { $listArgs += @('-Config', $cfgArg) }
$names = @(& powershell.exe @base @listArgs | Where-Object { $_ -match '^\S+$' })
if ($names.Count -eq 0) { throw 'no matching configuration' }
$null = & powershell.exe @base -BuildToolsOnly
if ($LASTEXITCODE -ne 0) { throw 'tool build failed' }
$pass = @()
$passthru = @('-Gap', "$Gap", '-Lat', "$Lat")
if ($Measure) { $passthru += '-Measure' }
if ($Inject) { $passthru += '-Inject' }
if ($InjectBurst) { $passthru += '-InjectBurst' }
if ($InjectBurstRef) { $passthru += '-InjectBurstRef' }
if ($Pcm) { $passthru += '-Pcm' }
if ($NoPng) { $passthru += '-NoPng' }
$running = @()
$results = @{}
$queue = New-Object System.Collections.Queue
foreach ($n in $names) { $queue.Enqueue($n) }
function Wait-One {
    while ($true) {
        foreach ($r in @($script:running)) {
            if ($r.Proc.HasExited) {
                $r.Proc.WaitForExit()
                $secs = [int]((Get-Date) - $r.Start).TotalSeconds
                $log = ''
                for ($try = 0; $try -lt 20; $try++) {
                    try {
                        $fs = New-Object System.IO.FileStream($r.Log, 'Open', 'Read', 'ReadWrite')
                        $sr = New-Object System.IO.StreamReader($fs)
                        $log = $sr.ReadToEnd()
                        $sr.Close()
                        break
                    } catch { Start-Sleep -Milliseconds 250 }
                }
                $verdict = [regex]::Matches($log, '(?m)^TEST (PASS|FAIL): [^\r\n]*') | Select-Object -Last 1
                $ok = ($r.Proc.ExitCode -eq 0) -and $verdict -and ($verdict.Value -like 'TEST PASS*')
                $script:results[$r.Name] = $ok
                Write-Output ("PAR {0}: {1} ({2} s)" -f $r.Name, $(if ($ok) { 'PASS' } else { 'FAIL' }), $secs)
                $script:running = @($script:running | Where-Object { $_.Name -ne $r.Name })
                return
            }
        }
        Start-Sleep -Milliseconds 500
    }
}
while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt $Jobs) {
        $n = $queue.Dequeue()
        $log = Join-Path $LogDir "${Prefix}_$n.log"
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList ($base + @('-Config', $n) + $passthru) -NoNewWindow -PassThru `
             -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        $null = $p.Handle
        $running += @{ Name = $n; Proc = $p; Log = $log; Start = Get-Date }
    }
    if ($running.Count -gt 0) { Wait-One }
}
$passed = @($results.Values | Where-Object { $_ }).Count
Write-Output "PAR RESULT: $passed of $($results.Count) passed"
if ($passed -ne $results.Count) { exit 1 }
exit 0
