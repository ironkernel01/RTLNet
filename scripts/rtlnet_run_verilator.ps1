<#
-------------------------------------------------------------------------------
File: rtlnet_run_verilator.ps1
Purpose: run one RTLNet self-checking testbench in Verilator 5 (MSYS2 UCRT64) and turn its verdict into an
  exit code; the Verilator counterpart of rtlnet_run_sim.ps1 (same parameters, same summary line).
Overview:
  * Verilator and g++ come from the MSYS2 UCRT64 install found by Resolve-RtlnetVerilator
    (rtlnet_tools.ps1). The bench is built with --binary --timing; the gcc 16 libstdc++ link problem at
    -Os is avoided with -MAKEFLAGS 'OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2'.
  * The filelist (paths relative to the repository root, nested -f, +incdir+, +define+, comments) is expanded
    into .sim/verilator/<bench>[_<tag>]/ (build, build.sh, build.log, run.log). The technology define
    RTLNET_TECH_GENERIC is always set, so rtlnet_ram_core compiles its behavioural branch (no XPM).
  * PASS requires: build without %Error, run exit code 0, exactly the anchored line `TEST PASS: <bench>`
    (optional `KERNEL:` prefix), no `TEST FAIL`, no %Error / %Warning-ASSERT style runtime error line.
    With -ExpectFail (the +INJECT_FAILURE negative control) the anchored `TEST FAIL: <bench>` line is required.
  * -Threads N builds the model with --threads N (long runs). -Extra adds raw verilator arguments.
  * Prints `RTLNET_SIM: PASS|FAIL <bench>[<tag>] ...` and exits 0 on PASS, 1 otherwise.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_run_verilator.ps1 `
      -Bench tb_rtlnet_h264_bitpack -Filelist ip/rtlnet_h264_enc/testbench/tb_rtlnet_h264_bitpack.f
  Options: -Tag <name>, -Defines A,B=1, -PlusArgs INJECT_FAILURE,SEED=5, -ExpectFail, -Threads 4,
    -TimeoutSeconds 3600, -Trace (write waves.fst).
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Bench,
    [Parameter(Mandatory = $true)][string]$Filelist,
    [string]$Tag = '',
    [string[]]$Defines = @(),
    [string[]]$PlusArgs = @(),
    [switch]$ExpectFail,
    [int]$Threads = 1,
    [string[]]$Extra = @(),
    [int]$TimeoutSeconds = 3600,
    [switch]$Trace
)
$ErrorActionPreference = 'Stop'
$Defines  = @($Defines  | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
$PlusArgs = @($PlusArgs | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'rtlnet_tools.ps1')
$Vl      = Resolve-RtlnetVerilator
$RunName = if ($Tag) { "${Bench}_$Tag" } else { $Bench }
$WorkDir = Join-Path $Repo ".sim/verilator/$RunName"

function Write-Summary([string]$verdict, [string]$detail) {
    Write-Output ("RTLNET_SIM: {0} {1} {2}" -f $verdict, $RunName, $detail)
}
function To-Fwd([string]$p) { return ($p -replace '\\', '/') }
function To-Msys([string]$p) {
    $f = To-Fwd $p
    if ($f -match '^([A-Za-z]):/(.*)$') { return "/$($Matches[1].ToLower())/$($Matches[2])" }
    return $f
}

# ----- expand the filelist ---------------------------------------------------
$srcs = New-Object System.Collections.Generic.List[string]
$incs = New-Object System.Collections.Generic.List[string]
$defs = New-Object System.Collections.Generic.List[string]
function Expand-Filelist([string]$path, [int]$depth) {
    if ($depth -gt 8) { throw "filelist nesting too deep at $path" }
    $full = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $Repo $path }
    if (-not (Test-Path -LiteralPath $full)) { throw "filelist not found: $path" }
    foreach ($raw in Get-Content -LiteralPath $full) {
        $line = ($raw -replace '(#|//).*$', '').Trim()
        if (-not $line) { continue }
        if ($line -match '^-f\s+(.+)$') { Expand-Filelist $Matches[1].Trim() ($depth + 1); continue }
        if ($line -match '^\+incdir\+(.+)$') {
            $d = $Matches[1]; $d = if ([System.IO.Path]::IsPathRooted($d)) { $d } else { Join-Path $Repo $d }
            $m = To-Fwd $d
            if (-not $incs.Contains($m)) { $incs.Add($m) }
            continue
        }
        if ($line -match '^\+define\+(.+)$') { $defs.Add($Matches[1]); continue }
        $s = if ([System.IO.Path]::IsPathRooted($line)) { $line } else { Join-Path $Repo $line }
        if (-not (Test-Path -LiteralPath $s)) { throw "source not found: $line (from $path)" }
        $s = To-Fwd ((Resolve-Path -LiteralPath $s).Path)
        if (-not $srcs.Contains($s)) { $srcs.Add($s) }
    }
}
Expand-Filelist $Filelist 0
foreach ($d in $Defines) { $defs.Add($d) }
$defs.Add('RTLNET_TECH_GENERIC')

if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir, "$WorkDir/tmp" | Out-Null

$argLines = @('--binary', '--timing', '--top-module', $Bench, '--Mdir', 'obj', '-o', 'simv',
              '--timescale', '1ns/1ps', '-Wno-fatal', '-Wno-lint', '-Wno-style', '-Wno-TIMESCALEMOD',
              '-Wno-UNOPTFLAT', '-Wno-IMPLICIT', '-Wno-INITIALDLY',
              '-MAKEFLAGS', "'OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2'")
if ($Threads -gt 1) { $argLines += @('--threads', "$Threads") }
if ($Trace) { $argLines += @('--trace-fst') }
foreach ($i in $incs) { $argLines += "+incdir+$i" }
foreach ($d in $defs) { $argLines += "+define+$d" }
$argLines += $Extra
$argLines += $srcs
$plus = ($PlusArgs | ForEach-Object { '+' + $_ }) -join ' '
$wd = To-Msys $WorkDir
$sh = @(
    '#!/bin/bash',
    'export MSYSTEM=UCRT64',
    'export PATH=/ucrt64/bin:/usr/bin:/bin',
    "export TMPDIR=$wd/tmp",
    'export TMP=$TMPDIR TEMP=$TMPDIR',
    "cd $wd || exit 1",
    ('verilator ' + ($argLines -join ' ') + ' > build.log 2>&1'),
    'rc=$?',
    'if [ $rc -ne 0 ]; then echo "build rc=$rc" >> build.log; exit 90; fi',
    ("./obj/simv $plus > run.log 2>&1"),
    'exit $?'
)
[System.IO.File]::WriteAllText((Join-Path $WorkDir 'build.sh'), (($sh -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$start = Get-Date
$p = Start-Process -FilePath $Vl.Bash -ArgumentList @('-c', "`"/usr/bin/bash $wd/build.sh`"") -WorkingDirectory $WorkDir -NoNewWindow -PassThru `
     -RedirectStandardOutput (Join-Path $WorkDir 'sh_out.txt') -RedirectStandardError (Join-Path $WorkDir 'sh_err.txt')
$null = $p.Handle
if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    try { & taskkill /T /F /PID $p.Id | Out-Null } catch { }
    Write-Summary 'FAIL' "timeout after $TimeoutSeconds s"; exit 1
}
$rc = $p.ExitCode
$secs = [int]((Get-Date) - $start).TotalSeconds
$buildLog = Join-Path $WorkDir 'build.log'
$runLog = Join-Path $WorkDir 'run.log'
$btext = if (Test-Path -LiteralPath $buildLog) { [System.IO.File]::ReadAllText($buildLog) } else { '' }
$be = [regex]::Match($btext, '(?m)^%Error[^\r\n]*')
if ($rc -eq 90 -or $be.Success) {
    $why = if ($be.Success) { $be.Value } else { 'build failed' }
    Write-Summary 'FAIL' "$why (log $buildLog)"; exit 1
}
if (-not (Test-Path -LiteralPath $runLog)) { Write-Summary 'FAIL' "no run log (rc=$rc)"; exit 1 }
$text = [System.IO.File]::ReadAllText($runLog)
$esc = [regex]::Escape($Bench)
$passLine = [regex]::Match($text, "(?m)^(KERNEL:\s+)?TEST PASS:\s+$esc\b[^\r\n]*")
$failLine = [regex]::Match($text, "(?m)^(KERNEL:\s+)?TEST FAIL:\s+$esc\b[^\r\n]*")
$errLine  = [regex]::Match($text, "(?m)^.*(%Error|%Fatal).*$")
if ($ExpectFail) {
    if ($failLine.Success -and -not $passLine.Success) {
        Write-Summary 'PASS' ("expected failure seen: " + $failLine.Value.Trim() + " ($secs s)"); exit 0
    }
    Write-Summary 'FAIL' "negative control did not report TEST FAIL (rc=$rc)"; exit 1
}
if ($failLine.Success) { Write-Summary 'FAIL' ($failLine.Value.Trim()); exit 1 }
if ($errLine.Success)  { Write-Summary 'FAIL' ($errLine.Value.Trim() + " (log $runLog)"); exit 1 }
if (-not $passLine.Success) { Write-Summary 'FAIL' "no anchored TEST PASS line (rc=$rc, log $runLog)"; exit 1 }
Write-Summary 'PASS' ($passLine.Value.Trim() + " ($secs s)")
exit 0
