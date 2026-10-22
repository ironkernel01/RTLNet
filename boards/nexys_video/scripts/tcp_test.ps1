<#
-------------------------------------------------------------------------------
File: tcp_test.ps1
Purpose: host-side hardware test of the CPU network path of the Nexys Video
  network build: the firmware's lwIP TCP echo server (port 7) and TCP iperf
  server (rtlnet_lwiperf, port 5001), alone and together with the RTL UDP iperf
  server, from the PC over the bench network.
Overview:
  1. TCP echo alone: microblaze/firmware/test/tcp_echo_client.py, 4
     connections, every payload size 1 B .. 64 KiB (PASS line required).
  2. TCP iperf alone, PC -> board: iperf -c <board> -t <s> (TCP). The
     throughput is parsed from the iperf client's summary line.
  3. Board -> PC modes of the iperf 2 client, each a gate with its throughput
     reported: -R (reverse: the board sends on the client's connection), -r
     (tradeoff: after the client finished the board connects back to the
     client's listener on the PC, port 5001) and -d (dual: the connect-back
     starts at once). A blocked connect-back (Windows Firewall on the PC)
     shows as a missing second line and fails the step; the script never
     changes the firewall.
  4. Coexistence: the TCP echo client, a TCP iperf run and a UDP iperf run
     (-u -b <UdpRate>, the RTL leaf) at the same time; all three must finish
     (echo PASS, both iperf summaries present).
  * Ends with exactly one anchored line: TCP_TEST: PASS <n>/<n> or
    TCP_TEST: FAIL <failed>/<n>; exit code 0 only on PASS. Measured numbers
    are printed for the record.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/tcp_test.ps1 `
    [-Board 192.169.1.199] [-Seconds 10] [-UdpRate 20M] [-Iperf C:\IronKernel\tools\iperf\iperf.exe]
Revision: 10-22-2026
  * 10-22-2026: initial version.
  * 10-22-2026: -R, -r and -d are gates with throughput (rtlnet_lwiperf).
-------------------------------------------------------------------------------
#>
param(
    [string]$Board = '192.169.1.199',
    [int]$Seconds = 10,
    [string]$UdpRate = '20M',
    [string]$Iperf = 'C:\IronKernel\tools\iperf\iperf.exe'
)
# Native tools write to stderr (iperf errors); PowerShell 5.1 turns that into
# error records under 2>&1, so the script continues and checks the text.
$ErrorActionPreference = 'Continue'
$Repo   = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Client = Join-Path $Repo 'microblaze\firmware\test\tcp_echo_client.py'
$script:results = @()
function Record([string]$name, [bool]$ok, [string]$detail) {
    $script:results += [pscustomobject]@{ Step = $name; Ok = $ok; Detail = $detail }
    Write-Output ("  {0,-4} {1,-36} {2}" -f ($(if ($ok) { 'ok' } else { 'FAIL' }), $name, $detail))
}
function Iperf-Rate([string[]]$lines) {
    # Last "<n> <unit>bits/sec" figure of the client summary.
    $m = $lines | Select-String -Pattern '([\d.]+)\s+([KMG]?)bits/sec' | Select-Object -Last 1
    if (-not $m) { return $null }
    $v = [double]$m.Matches[0].Groups[1].Value
    switch ($m.Matches[0].Groups[2].Value) { 'G' { $v *= 1e6 } 'M' { $v *= 1e3 } '' { $v /= 1e3 } }
    return $v   # kbit/s
}
if (-not (Test-Path -LiteralPath $Iperf)) { Write-Output "TCP_TEST: FAIL no iperf at $Iperf"; exit 1 }

Write-Output "tcp_test: board $Board, iperf $Iperf, $Seconds s per run"

# 1. TCP echo alone.
$echo = & python $Client $Board --conns 4 --timeout 30 2>&1 | ForEach-Object { "$_" }
$echo | Select-Object -Last 3 | ForEach-Object { Write-Output "    $_" }
$v = $echo | Where-Object { $_ -match '^TCP_ECHO_TEST: ' } | Select-Object -Last 1
Record 'TCP echo, 4 connections' ($v -match '^TCP_ECHO_TEST: PASS') "$v"

# 2. TCP iperf alone, PC -> board.
$tcp = & $Iperf -c $Board -t $Seconds -f k 2>&1 | ForEach-Object { "$_" }
$tcp | Select-Object -Last 3 | ForEach-Object { Write-Output "    $_" }
$r = Iperf-Rate $tcp
Record 'TCP iperf PC -> board' ($null -ne $r -and $r -gt 0) $(if ($r) { "{0:N0} kbit/s" -f $r } else { 'no summary' })

# 3. Board -> PC: -R on the client's connection, -r and -d by connect-back.
#    The throughput is the board's sending line: "[ *1]" for -R, "[  2]" for -r and -d.
foreach ($mode in @('-R', '-r', '-d')) {
    $j = Start-Job -ScriptBlock { param($i, $b, $s, $m) & $i -c $b -t $s $m -f k 2>&1 | ForEach-Object { "$_" } } `
        -ArgumentList $Iperf, $Board, $Seconds, $mode
    if (-not (Wait-Job -Job $j -Timeout ($Seconds * 2 + 30))) { Stop-Job $j; Write-Output "    ${mode}: no result within $($Seconds * 2 + 30) s (stopped)" }
    $out = @(Receive-Job $j)
    Remove-Job -Force $j
    $out | Select-Object -Last 4 | ForEach-Object { Write-Output "    ${mode}: $_" }
    $pat = $(if ($mode -ceq '-R') { '^\[\s*\*1\]' } else { '^\[\s+2\]' })
    $r = Iperf-Rate @($out | Where-Object { $_ -match $pat -and $_ -match 'bits/sec' })
    Record "TCP iperf board -> PC ($mode)" ($null -ne $r -and $r -gt 0) $(if ($r) { "{0:N0} kbit/s" -f $r } else { 'no board -> PC line' })
}

# 4. Coexistence: echo + TCP iperf + UDP iperf at the same time.
$jEcho = Start-Job -ScriptBlock { param($c, $b) & python $c $b --conns 2 --rounds 2 --timeout 60 2>&1 | ForEach-Object { "$_" } } -ArgumentList $Client, $Board
$jTcp  = Start-Job -ScriptBlock { param($i, $b, $s) & $i -c $b -t $s -f k 2>&1 | ForEach-Object { "$_" } } -ArgumentList $Iperf, $Board, $Seconds
$jUdp  = Start-Job -ScriptBlock { param($i, $b, $s, $u) & $i -c $b -u -b $u -t $s -f k 2>&1 | ForEach-Object { "$_" } } -ArgumentList $Iperf, $Board, $Seconds, $UdpRate
$null = Wait-Job -Job $jEcho, $jTcp, $jUdp -Timeout ($Seconds * 3 + 120)
$oEcho = @(Receive-Job $jEcho); $oTcp = @(Receive-Job $jTcp); $oUdp = @(Receive-Job $jUdp)
Remove-Job -Force $jEcho, $jTcp, $jUdp
$v = $oEcho | Where-Object { $_ -match '^TCP_ECHO_TEST: ' } | Select-Object -Last 1
Record 'together: TCP echo' ($v -match '^TCP_ECHO_TEST: PASS') "$v"
$r = Iperf-Rate $oTcp
Record 'together: TCP iperf' ($null -ne $r -and $r -gt 0) $(if ($r) { "{0:N0} kbit/s" -f $r } else { 'no summary' })
$oUdp | Select-Object -Last 2 | ForEach-Object { Write-Output "    udp: $_" }
$r = Iperf-Rate $oUdp
Record 'together: UDP iperf (RTL leaf)' ($null -ne $r -and $r -gt 0) $(if ($r) { "{0:N0} kbit/s" -f $r } else { 'no summary' })

$failed = @($script:results | Where-Object { -not $_.Ok }).Count
$total = $script:results.Count
if ($failed -eq 0) { Write-Output "TCP_TEST: PASS $total/$total"; exit 0 }
Write-Output "TCP_TEST: FAIL $failed/$total"
exit 1
