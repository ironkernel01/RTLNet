<#
-------------------------------------------------------------------------------
File: offload_profile.ps1
Purpose: per-frame CPU time of the lwIP netif on the Nexys Video network build,
  for a firmware image built with -Define RTLNET_NETIF_PROFILE=1.
Overview:
  * For each state of the checksum offload {off, on} (CLI `offload all ...`)
    and each load {iperf PC -> board, iperf -R board -> PC, TCP echo x3}:
    `clear counters`, run the load, then `show cpu-path` and print the profile
    lines (wall time, busy share, per RX frame copy and lwIP input, per TX frame
    copy, DMA wait and start) with the load's throughput.
  * Prints one line OFFLOAD_PROFILE: DONE <n> rows; exit code 0 when every row
    has a profile (the image was built with the profile).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/offload_profile.ps1 `
    [-Port COM3] [-Board 192.169.1.199] [-Seconds 10] [-Label prof] [-Iperf <iperf.exe>]
Revision: 10-22-2026
  * 10-22-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string]$Port = 'COM3',
    [string]$Board = '192.169.1.199',
    [int]$Seconds = 10,
    [string]$Label = 'prof',
    [string]$Iperf = ''
)
$ErrorActionPreference = 'Continue'
$Repo   = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
$Python = Resolve-RtlnetPython
if (-not $Iperf) { $Iperf = Resolve-RtlnetIperf; if (-not $Iperf) { $Iperf = 'iperf.exe' } }
$Client = Join-Path $Repo 'microblaze\firmware\test\tcp_echo_client.py'
$PromptRe = '(rtlnet(\([a-z-]+\))?[>#])$'
$rows = 0
$bad = 0

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

function Run-Cli([string]$line) {
    $script:sp.Write("$line`r")
    return (Read-UntilPrompt $script:sp 8000) -replace "`r", ''
}

function Iperf-Mbit([string[]]$lines) {
    $m = $lines | Where-Object { $_ -match 'bits/sec' } | Select-String -Pattern '([\d.]+)\s+([KMG]?)bits/sec' | Select-Object -Last 1
    if (-not $m) { return $null }
    $v = [double]$m.Matches[0].Groups[1].Value
    switch ($m.Matches[0].Groups[2].Value) { 'G' { $v *= 1e3 } 'K' { $v /= 1e3 } '' { $v /= 1e6 } }
    return $v
}

$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.Handshake = [System.IO.Ports.Handshake]::None
$sp.ReadTimeout = 200
$sp.WriteTimeout = 2000
try { $sp.Open() } catch { Write-Output "OFFLOAD_PROFILE: FAIL cannot open ${Port}: $($_.Exception.Message)"; exit 1 }
$script:sp = $sp
try {
    $sp.DiscardInBuffer()
    $sp.Write([string][char]3)
    $sp.Write("`r")
    $sync = Read-UntilPrompt $sp 5000
    if (($sync -replace "`r", '').TrimEnd(' ') -notmatch $PromptRe) { Write-Output "OFFLOAD_PROFILE: FAIL no prompt"; exit 1 }
    [void](Run-Cli "end"); [void](Run-Cli "disable"); [void](Run-Cli "enable")
    foreach ($state in @('off', 'on')) {
        [void](Run-Cli "configure terminal"); [void](Run-Cli "offload all $state"); [void](Run-Cli "end")
        foreach ($load in @('iperf PC->board', 'iperf -R', 'echo x3')) {
            [void](Run-Cli "clear counters")
            $rate = $null
            if ($load -eq 'iperf PC->board') {
                $out = & $Iperf -c $Board -t $Seconds -f m 2>&1 | ForEach-Object { "$_" }
                $rate = Iperf-Mbit $out
            } elseif ($load -eq 'iperf -R') {
                $out = & $Iperf -c $Board -t $Seconds -R -f m 2>&1 | ForEach-Object { "$_" }
                $rate = Iperf-Mbit @($out | Where-Object { $_ -match '^\[\s*\*1\]' })
            } else {
                $rs = @()
                for ($i = 0; $i -lt 3; $i++) {
                    $e = & $Python $Client $Board --conns 4 --timeout 60 2>&1 | ForEach-Object { "$_" }
                    $v = $e | Where-Object { $_ -match '^TCP_ECHO_TEST: PASS' } | Select-Object -Last 1
                    if ($v -match 'throughput=([\d.]+) kbit/s') { $rs += [double]$Matches[1] / 1000.0 }
                }
                $rate = $(if ($rs.Count -gt 0) { ($rs | Measure-Object -Average).Average } else { $null })
            }
            $cp = Run-Cli "show cpu-path"
            $prof = @($cp -split "`n" | Where-Object { $_ -match 'CPU profile|Per RX frame|Per TX frame|DMA receive|DMA transmit' })
            $rows++
            if (-not ($cp -match 'Per RX frame')) { $bad++ }
            Write-Output ("--- {0} offload {1}, {2}: {3:N1} Mbit/s" -f $Label, $state, $load, $rate)
            $prof | ForEach-Object { Write-Output "    $($_.Trim())" }
        }
    }
    [void](Run-Cli "configure terminal"); [void](Run-Cli "offload all on"); [void](Run-Cli "end")
} finally {
    $sp.Close()
}
Write-Output "OFFLOAD_PROFILE: DONE $rows rows, $bad without profile"
if ($bad -eq 0 -and $rows -gt 0) { exit 0 }
exit 1
