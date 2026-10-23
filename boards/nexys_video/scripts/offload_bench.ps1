<#
-------------------------------------------------------------------------------
File: offload_bench.ps1
Purpose: hardware test and throughput measurement of the checksum offload
  (rtlnet_tcp_offload) on the Nexys Video network build: the CLI toggles, the
  hardware counters move, TCP echo stays correct with the offload on and off,
  and TCP iperf in both directions is measured for the offload off and on.
Overview:
  * The zero-copy options are compile-time (src/lwip/lwipopts.h, build.ps1
    -Define RTLNET_NETIF_ZERO_COPY_RX=0/1 and _TX=0/1); this script runs once per
    firmware image and labels its rows with -Label. The offload itself is
    switched at run time through the CLI (configure terminal, offload all on|off).
  * Steps: show offload (core found, CTRL), then for each state of
    {off, on}: set it, check that `show offload` reports it and that the lwIP
    flags agree (no MISMATCH line), TCP echo (4 connections, every payload size
    1 B .. 64 KiB, tcp_echo_client.py: PASS required), TCP iperf PC -> board and
    board -> PC (-R), -t <Seconds> each, <Runs> runs; with the offload on the
    hardware counters (tx_l4_patched, rx_verified) must have advanced and
    rx_l4_bad / rx_ip_bad / the netif drop counters must not have.
  * Prints one table row per (state, direction) with the mean throughput in
    Mbit/s and ends with exactly one line OFFLOAD_BENCH: PASS <n>/<n> or FAIL;
    exit code 0 only on PASS.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/offload_bench.ps1 `
    [-Port COM4] [-Board 192.169.1.199] [-Seconds 10] [-Runs 2] [-Label zc-both] [-Iperf C:\IronKernel\tools\iperf\iperf.exe]
Revision: 10-22-2026
  * 10-22-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string]$Port = 'COM4',
    [string]$Board = '192.169.1.199',
    [int]$Seconds = 10,
    [int]$Runs = 2,
    [string]$Label = 'run',
    [string]$Iperf = 'C:\IronKernel\tools\iperf\iperf.exe'
)
$ErrorActionPreference = 'Continue'
$Repo   = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Client = Join-Path $Repo 'microblaze\firmware\test\tcp_echo_client.py'
$PromptRe = '(rtlnet(\([a-z-]+\))?[>#])$'
$script:results = @()
$script:rows = @()

function Record([string]$name, [bool]$ok, [string]$detail) {
    $script:results += [pscustomobject]@{ Step = $name; Ok = $ok; Detail = $detail }
    Write-Output ("  {0,-4} {1,-44} {2}" -f ($(if ($ok) { 'ok' } else { 'FAIL' })), $name, $detail)
}

function Read-UntilPrompt($sp, [int]$timeoutMs) {
    $buf = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $chunk = $sp.ReadExisting()
        if ($chunk.Length -gt 0) {
            $buf += $chunk
            if ($buf.TrimEnd(' ') -match $PromptRe) {
                Start-Sleep -Milliseconds 50
                $more = $sp.ReadExisting()
                if ($more.Length -eq 0) { return $buf }
                $buf += $more
            }
        } else {
            Start-Sleep -Milliseconds 20
        }
    }
    return $buf
}

function Cli([string]$line) {
    $script:sp.Write("$line`r")
    return (Read-UntilPrompt $script:sp 8000) -replace "`r", ''
}

function Iperf-Mbit([string[]]$lines, [string]$pattern) {
    $m = $lines | Where-Object { $_ -match $pattern -and $_ -match 'bits/sec' } | Select-String -Pattern '([\d.]+)\s+([KMG]?)bits/sec' | Select-Object -Last 1
    if (-not $m) { return $null }
    $v = [double]$m.Matches[0].Groups[1].Value
    switch ($m.Matches[0].Groups[2].Value) { 'G' { $v *= 1e3 } 'K' { $v /= 1e3 } '' { $v /= 1e6 } }
    return $v
}

function Counter([string]$text, [string]$pattern) {
    $m = [regex]::Match($text, $pattern)
    if ($m.Success) { return [uint64]$m.Groups[1].Value }
    return [uint64]0
}

if (-not (Test-Path -LiteralPath $Iperf)) { Write-Output "OFFLOAD_BENCH: FAIL no iperf at $Iperf"; exit 1 }
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.Handshake = [System.IO.Ports.Handshake]::None
$sp.ReadTimeout = 200
$sp.WriteTimeout = 2000
try { $sp.Open() } catch { Write-Output "OFFLOAD_BENCH: FAIL cannot open ${Port}: $($_.Exception.Message)"; exit 1 }
$script:sp = $sp
try {
    $sp.DiscardInBuffer()
    $sp.Write([string][char]3)
    $sp.Write("`r")
    $sync = Read-UntilPrompt $sp 5000
    if (($sync -replace "`r", '').TrimEnd(' ') -notmatch $PromptRe) {
        Write-Output "OFFLOAD_BENCH: FAIL no prompt on $Port"; exit 1
    }
    [void](Cli "end"); [void](Cli "disable"); [void](Cli "enable")
    Write-Output "offload_bench: board $Board, label $Label, $Seconds s x $Runs per direction"

    $show = Cli "show offload"
    $show -split "`n" | ForEach-Object { Write-Output "    $_" }
    Record 'show offload: both paths confirmed' ($show -match 'Confirmed\s+: classifier \w+, offload TX yes, offload RX yes') ''
    $zcRx = ($show -match 'zero-copy RX on'); $zcTx = ($show -match 'zero-copy TX on')
    Write-Output "    firmware zero-copy: RX $zcRx, TX $zcTx"

    foreach ($state in @('off', 'on')) {
        [void](Cli "configure terminal")
        $o = Cli "offload all $state"
        [void](Cli "end")
        $s = Cli "show offload"
        $expectCtrl = $(if ($state -eq 'on') { '0x00000007' } else { '0x00000000' })
        Record "offload $state: CTRL $expectCtrl" ($s -match "CTRL\s+: $expectCtrl") ''
        Record "offload ${state}: lwIP flags agree" ($s -notmatch 'MISMATCH') ''
        [void](Cli "clear counters")

        # TCP echo, 4 connections, every payload size.
        $echo = & python $Client $Board --conns 4 --timeout 60 2>&1 | ForEach-Object { "$_" }
        $v = $echo | Where-Object { $_ -match '^TCP_ECHO_TEST: ' } | Select-Object -Last 1
        Record "offload ${state}: TCP echo" ($v -match '^TCP_ECHO_TEST: PASS') "$v"

        foreach ($dir in @('PC->board', 'board->PC')) {
            $rates = @()
            for ($i = 0; $i -lt $Runs; $i++) {
                if ($dir -eq 'PC->board') {
                    $out = & $Iperf -c $Board -t $Seconds -f m 2>&1 | ForEach-Object { "$_" }
                    $r = Iperf-Mbit $out '.'
                } else {
                    $out = & $Iperf -c $Board -t $Seconds -R -f m 2>&1 | ForEach-Object { "$_" }
                    $r = Iperf-Mbit @($out | Where-Object { $_ -match '^\[\s*\*1\]' }) '.'
                    if ($null -eq $r) { $r = Iperf-Mbit $out '.' }
                }
                if ($null -ne $r) { $rates += $r }
                $out | Select-Object -Last 2 | ForEach-Object { Write-Output "      $_" }
            }
            $mean = $(if ($rates.Count -gt 0) { ($rates | Measure-Object -Average).Average } else { 0 })
            Record "offload ${state}: iperf $dir" ($rates.Count -eq $Runs -and $mean -gt 0) ("{0:N1} Mbit/s over {1} run(s): {2}" -f $mean, $rates.Count, (($rates | ForEach-Object { '{0:N1}' -f $_ }) -join ', '))
            $script:rows += [pscustomobject]@{ Label = $Label; Offload = $state; Direction = $dir; Mbit = [math]::Round($mean, 1) }
        }

        $after = Cli "show offload"
        $txl4 = Counter $after 'l4 patched (\d+)'
        $rxv = Counter $after 'verified (\d+), ip bad'
        $rxipbad = Counter $after 'ip bad (\d+)'
        $rxl4bad = Counter $after 'l4 bad (\d+)'
        $dropi = Counter $after 'dropped bad ip (\d+)'
        $dropl = Counter $after 'bad l4 (\d+)'
        $dropn = Counter $after 'no trailer (\d+)'
        if ($state -eq 'on') {
            Record 'on: hardware inserted TX checksums' ($txl4 -gt 0) "tx l4 patched $txl4"
            Record 'on: hardware verified RX checksums' ($rxv -gt 0) "rx verified $rxv"
            Record 'on: no bad checksum, no policy drop' ($rxipbad -eq 0 -and $rxl4bad -eq 0 -and $dropi -eq 0 -and $dropl -eq 0 -and $dropn -eq 0) "ip bad $rxipbad, l4 bad $rxl4bad, drops $dropi/$dropl/$dropn"
        } else {
            Record 'off: hardware counters idle' ($txl4 -eq 0 -and $rxv -eq 0) "tx l4 patched $txl4, rx verified $rxv"
        }
    }
    [void](Cli "configure terminal"); [void](Cli "offload all on"); [void](Cli "end")
} finally {
    $sp.Close()
}
Write-Output ""
Write-Output "| firmware | offload | PC->board Mbit/s | board->PC Mbit/s |"
foreach ($st in @('off', 'on')) {
    $a = ($script:rows | Where-Object { $_.Offload -eq $st -and $_.Direction -eq 'PC->board' }).Mbit
    $b = ($script:rows | Where-Object { $_.Offload -eq $st -and $_.Direction -eq 'board->PC' }).Mbit
    Write-Output ("| {0} | {1} | {2} | {3} |" -f $Label, $st, $a, $b)
}
$failed = @($script:results | Where-Object { -not $_.Ok }).Count
$total = $script:results.Count
if ($failed -eq 0) { Write-Output "OFFLOAD_BENCH: PASS $total/$total"; exit 0 }
Write-Output "OFFLOAD_BENCH: FAIL $failed/$total"
exit 1
