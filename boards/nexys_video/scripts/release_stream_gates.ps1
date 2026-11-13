<#
-------------------------------------------------------------------------------
File: release_stream_gates.ps1
Purpose: the stream gates of the H.264 encoder release images (Baseline + deblocking, High profile CABAC + deblocking, demo): one run of stream_test.ps1 per
  line of the matrix below, every run decoded with FFmpeg and JM, 0 dropped pictures required, a summary file at the end.
Overview:
  * Each run is stream_test.ps1 with -Jm -CcTolPct 0.01 and -FilePrefix phase2i_<Label>_<run>; its transcript is kept as
    boards/nexys_video/build/phase2i_<Label>_<run>.log. The board lock is taken by stream_test.ps1 for each run.
  * Matrix (both modes, 1080p30 and 720p30, 20 s per run unless noted, pattern "all" speed 4; the QP sweeps use the pattern "scroll": at QP 24 and 26 the
    pattern "all" (it includes noise) makes 31 to 32 Mb/s at 1080p30 and the TS mux of the MicroBlaze V (99 % load) drops pictures, filter on or off alike):
      irq_on, poll_on, irq_off, poll_off  interrupt or polled notification, deblocking on or off, constant QP 28
      switch                              -SwitchDeblock (on, off at one third, on at two thirds, 30 s), interrupt
      rc8000, rc16000                     rate control 8,000 and 16,000 kb/s, deblocking on
      qp24 qp26 qp28 qp32, qp*_off        constant QP sweep with the filter on and off (profile baseline: CAVLC)
      qp*_cabac, qp*_cabac_off            the same with -Profile high (CABAC), only with -High
  * The summary (build/phase2i_<Label>_gates_summary.txt) has one line per run: result line of stream_test, the RUN_SUMMARY lines (bit rate, PSNR).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/release_stream_gates.ps1 -Label base [-High] [-Seconds 20] [-Only <regex>]
Revision: 11-12-2026
  * 11-12-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Label,
    [switch]$High,
    [int]$Seconds = 20,
    [string]$Only = '.',
    [string]$HostIp = ''
)
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Build = Join-Path $Board 'build'
$st = Join-Path $PSScriptRoot 'stream_test.ps1'
$summary = Join-Path $Build "phase2i_${Label}_gates_summary.txt"
$runs = @()
$runs += ,@('irq_on',   @('-Notify', 'interrupt', '-Deblock', 'on',  '-Qp', '28'))
$runs += ,@('poll_on',  @('-Notify', 'polled',    '-Deblock', 'on',  '-Qp', '28'))
$runs += ,@('irq_off',  @('-Notify', 'interrupt', '-Deblock', 'off', '-Qp', '28'))
$runs += ,@('poll_off', @('-Notify', 'polled',    '-Deblock', 'off', '-Qp', '28'))
$runs += ,@('switch',   @('-SwitchDeblock', '-Qp', '28', '-Seconds', '30'))
$runs += ,@('rc8000',   @('-Bitrate', '8000',  '-Deblock', 'on'))
$runs += ,@('rc16000',  @('-Bitrate', '16000', '-Deblock', 'on'))
foreach ($q in 24, 26, 28, 32) {
    $runs += ,@("qp${q}",     @('-Qp', "$q", '-Deblock', 'on',  '-Pattern', 'scroll'))
    $runs += ,@("qp${q}_off", @('-Qp', "$q", '-Deblock', 'off', '-Pattern', 'scroll'))
}
if ($High) {
    foreach ($q in 24, 26, 28, 32) {
        $runs += ,@("qp${q}_cabac",     @('-Profile', 'high', '-Qp', "$q", '-Deblock', 'on',  '-Pattern', 'scroll'))
        $runs += ,@("qp${q}_cabac_off", @('-Profile', 'high', '-Qp', "$q", '-Deblock', 'off', '-Pattern', 'scroll'))
    }
    $runs += ,@('switch_cabac', @('-Profile', 'high', '-SwitchDeblock', '-Qp', '28', '-Seconds', '30'))
    $runs += ,@('rc8000_cabac', @('-Profile', 'high', '-Bitrate', '8000', '-Deblock', 'on'))
}
$out = New-Object System.Collections.Generic.List[string]
$fail = 0
foreach ($r in $runs) {
    $name = $r[0]
    if ($name -notmatch $Only) { continue }
    $extra = @($r[1])
    $sec = $Seconds
    $k = [array]::IndexOf($extra, '-Seconds')
    if ($k -ge 0) { $sec = [int]$extra[$k + 1]; $extra = @($extra | Select-Object -First $k) + @($extra | Select-Object -Skip ($k + 2)) }
    $pat = 'all'
    $k = [array]::IndexOf($extra, '-Pattern')
    if ($k -ge 0) { $pat = [string]$extra[$k + 1]; $extra = @($extra | Select-Object -First $k) + @($extra | Select-Object -Skip ($k + 2)) }
    $a = @('-Mode', 'both', '-Seconds', "$sec", '-Jm', '-CcTolPct', '0.01', '-Pattern', $pat, '-Speed', '4', '-SkipVlc')
    if ($HostIp) { $a += @('-HostIp', $HostIp) }
    $a += $extra
    $a += @('-FilePrefix', "phase2i_${Label}_${name}")
    $log = Join-Path $Build "phase2i_${Label}_${name}.log"
    Write-Host ("=== {0} {1}" -f $name, ($a -join ' '))
    $t0 = Get-Date
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $st @a > $log 2>&1
    $rc = $LASTEXITCODE
    $last = (Get-Content -LiteralPath $log | Where-Object { $_ -match '^STREAM_TEST:' } | Select-Object -Last 1)
    $rs = @(Get-Content -LiteralPath $log | Where-Object { $_ -match '^RUN_SUMMARY' })
    $line = "{0,-16} rc={1} {2} ({3:N0} s)" -f $name, $rc, $last, ((Get-Date) - $t0).TotalSeconds
    Write-Host $line
    $out.Add($line)
    foreach ($s in $rs) { $out.Add("    " + $s) }
    if ($rc -ne 0) { $fail++ }
    Set-Content -LiteralPath $summary -Value $out -Encoding ascii
}
$out.Add("RELEASE_STREAM_GATES ${Label}: $(if ($fail -eq 0) { 'PASS' } else { "FAIL $fail" }) ($($runs.Count) defined)")
Set-Content -LiteralPath $summary -Value $out -Encoding ascii
Write-Host $out[$out.Count - 1]
exit $fail
