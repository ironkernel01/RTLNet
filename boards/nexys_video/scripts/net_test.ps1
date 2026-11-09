<#
-------------------------------------------------------------------------------
File: net_test.ps1
Purpose: hardware network test of the RTLNet Nexys Video network image:
  board-side checks over the CLI on the USB-UART, and host-side checks from
  this PC's wired NIC when it is connected to the same network.
Overview:
  * Board side (always): PHY identity 0x001CC915 and RX delay on (show phy);
    link up at the expected speed, MAC RXC qualified and receive path running
    (show interfaces); a DHCP lease and the effective address switched to it
    (show dhcp, show ip); a DHCP renew moves the MAC RX/TX counters with no
    RX_BAD; then speed 10 forced from the CLI, the same checks at 10 Mb/s,
    and speed auto restored.
  * Host side (only when the NIC -Nic is Up): ARP entry of the board after a
    ping (arp -a), ping sweep 0 / 64 / 1472 bytes with -n 20 each, the UDP
    echo client (cores/rtlnet_udp_echo/testbench/udp_echo_client.py) to port
    7, and iperf 2 at 90 % of the link rate in both directions (-u, -u -R; at most 1 %
    loss) with the binary from -Iperf, PATH, RTLNET_IPERF or <repo>/../tools/iperf. A host check that
    cannot run is reported BLOCKED with the reason, never as passed.
  * Prints the transcript to boards/nexys_video/build/net_test_transcript.txt
    and one line per check; the last line is "NET_TEST: PASS n/n" (blocked
    host checks listed separately) or "NET_TEST: FAIL f/n"; exit 0 on PASS.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/net_test.ps1 `
    [-Port COM3] [-Nic Ethernet] [-Speed 100]
Revision: 10-22-2026
  * 10-22-2026: initial version; iperf at 90 % line rate both ways, -Iperf.
-------------------------------------------------------------------------------
#>
param(
    [string]$Port = 'COM3',
    [string]$Nic = 'Ethernet',
    [int]$Speed = 100,
    [string]$Iperf = ''
)
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
$TranscriptPath = Join-Path $Board 'build\net_test_transcript.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $TranscriptPath) | Out-Null
$PromptRe = '(rtlnet(\([a-z-]+\))?[>#])\s*$'
$script:log = New-Object System.Text.StringBuilder
$script:results = @()
$script:blocked = @()

function Note([string]$name, [bool]$ok, [string]$detail) {
    $script:results += [pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail }
}

function Send-Cli($sp, [string]$cmd, [int]$timeoutMs = 6000) {
    $sp.Write($cmd + "`r")
    $buf = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $c = $sp.ReadExisting()
        if ($c.Length -gt 0) {
            $buf += $c
            if (($buf -replace "`r", '') -match $PromptRe) {
                Start-Sleep -Milliseconds 100
                $more = $sp.ReadExisting()
                if ($more.Length -eq 0) { break }
                $buf += $more
            }
        } else { Start-Sleep -Milliseconds 20 }
    }
    [void]$script:log.Append($buf)
    return ($buf -replace "`r", '')
}

function Wait-Link($sp, [int]$mbps, [int]$timeoutS = 15) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutS) {
        $o = Send-Cli $sp 'show interfaces'
        if ($o -match "eth0 is up, $mbps Mb/s full duplex") { return $o }
        Start-Sleep -Milliseconds 1000
    }
    return $o
}

function Counter([string]$text, [string]$name) {
    if ($text -match "$name (\d+)") { return [int]$Matches[1] }
    return -1
}

function Board-Checks($sp, [int]$mbps, [string]$tag) {
    $o = Wait-Link $sp $mbps
    Note "$tag link up $mbps Mb/s full duplex" ($o -match "eth0 is up, $mbps Mb/s full duplex") ''
    Note "$tag MAC RXC qualified, receive path running" ($o -match 'RXC ok .* receive path running') ''
    $o = Send-Cli $sp 'show phy'
    Note "$tag PHY ID and RX delay" (($o -match 'ID 0x001CC915') -and ($o -match '\(RX delay on\)')) ''
    Note "$tag PHYSR speed" ($o -match "Link\s+: up, $mbps Mb/s full duplex") ''
    $before = Send-Cli $sp 'show counters'
    [void](Send-Cli $sp 'configure terminal'); [void](Send-Cli $sp 'ip dhcp'); [void](Send-Cli $sp 'renew'); [void](Send-Cli $sp 'end')
    Start-Sleep -Milliseconds 2500
    $after = Send-Cli $sp 'show counters'
    $rx0 = Counter $before 'rx good'; $rx1 = Counter $after 'rx good'
    $tx0 = Counter $before ', tx'; $tx1 = Counter $after ', tx'
    Note "$tag DHCP renew moves MAC counters" (($rx1 -gt $rx0) -and ($tx1 -gt $tx0)) "rx $rx0->$rx1 tx $tx0->$tx1"
    Note "$tag no RX_BAD" ((Counter $after 'rx bad') -eq 0) ''
    $o = Send-Cli $sp 'show dhcp'
    Note "$tag DHCP lease" ($o -match 'state BOUND, bound') ''
    $o = Send-Cli $sp 'show ip'
    Note "$tag effective IP from the lease" ($o -match 'Effective IPv4\s+: (\d+\.\d+\.\d+\.\d+) .*\(DHCP lease\)') ''
    if ($o -match 'Effective IPv4\s+: (\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
    return ''
}

$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
try { $sp.Open() } catch { Write-Output "NET_TEST: FAIL cannot open ${Port}: $($_.Exception.Message)"; exit 1 }
$boardIp = ''
try {
    $sp.DiscardInBuffer()
    $sp.Write([string][char]3)
    $o = Send-Cli $sp ''
    if ($o -notmatch $PromptRe) { Write-Output "NET_TEST: FAIL no prompt on $Port"; exit 1 }
    $o = Send-Cli $sp 'show version'
    Note 'network image' ($o -match 'Network cores\s+: in this build') ''
    if ($o -notmatch 'rtlnet#') { [void](Send-Cli $sp 'enable') }
    if ((Send-Cli $sp '') -notmatch 'rtlnet#') { [void](Send-Cli $sp 'end'); [void](Send-Cli $sp 'enable') }
    $boardIp = Board-Checks $sp $Speed "[$Speed]"

    # Host side, at the expected speed.
    $nicUp = $false
    $a = Get-NetAdapter -Name $Nic -ErrorAction SilentlyContinue
    if ($a -and $a.Status -eq 'Up') { $nicUp = $true }
    if (-not $nicUp) {
        $why = if ($a) { "PC NIC '$Nic' is $($a.Status)" } else { "PC NIC '$Nic' not found" }
        foreach ($t in @('arp entry', 'ping 0/64/1472 x20', 'UDP echo client', 'iperf -u')) { $script:blocked += "$t ($why)" }
    } elseif (-not $boardIp) {
        $script:blocked += 'host checks (board address unknown)'
    } else {
        foreach ($len in @(0, 64, 1472)) {
            $p = & ping -n 20 -l $len -w 1000 $boardIp
            [void]$script:log.Append(($p -join "`n") + "`n")
            $loss = ($p | Select-String -Pattern 'Lost = (\d+)').Matches.Groups[1].Value
            Note "ping -l $len -n 20" ($loss -eq '0') "lost $loss"
        }
        $arp = & arp -a
        Note 'ARP entry of the board on the PC' ([bool]($arp | Select-String -SimpleMatch $boardIp | Select-String -Pattern '02-49-4b-52-4e-01')) ''
        $py = Join-Path $Repo 'cores\rtlnet_udp_echo\testbench\udp_echo_client.py'
        $e = & (Resolve-RtlnetPython) -I $py $boardIp -p 7 -n 200 --timeout 1.0 2>&1
        [void]$script:log.Append(($e -join "`n") + "`n")
        Note 'UDP echo client 200 datagrams' ($LASTEXITCODE -eq 0) ($e | Select-Object -Last 1)
        # iperf 2: -Iperf, else iperf/iperf2 on PATH, else rtlnet_tools.ps1 (RTLNET_IPERF, <repo>/../tools/iperf).
        $ipexe = $null
        if ($Iperf -and (Test-Path -LiteralPath $Iperf)) { $ipexe = $Iperf }
        if (-not $ipexe) { $c = Get-Command iperf -ErrorAction SilentlyContinue; if ($c) { $ipexe = $c.Source } }
        if (-not $ipexe) { $c = Get-Command iperf2 -ErrorAction SilentlyContinue; if ($c) { $ipexe = $c.Source } }
        if (-not $ipexe) { $ipexe = Resolve-RtlnetIperf }
        if ($ipexe) {
            # Offered load 90 % of the link rate, 1470-byte datagrams, 5 s, both directions;
            # pass = a loss figure was reported and it is at most 1 %.
            $rate = "$([int]($Speed * 0.9))M"
            foreach ($dir in @(@{ name = 'iperf -u (PC to board)'; args = @() }, @{ name = 'iperf -u -R (board to PC)'; args = @('-R') })) {
                $r = & $ipexe -c $boardIp -u -b $rate -t 5 -l 1470 @($dir.args) 2>&1
                [void]$script:log.Append(($r -join "`n") + "`n")
                $line = $r | Select-String -Pattern '(\d+(\.\d+)?) Mbits/sec.*?(\d+)/\s*(\d+)\s*\(([\d.e+-]+)%\)' | Select-Object -Last 1
                if ($line) {
                    $m = $line.Matches[0]
                    $mbps = [double]$m.Groups[1].Value; $lost = [double]$m.Groups[3].Value; $tot = [double]$m.Groups[4].Value
                    $lossPct = if ($tot -gt 0) { [math]::Round(100.0 * $lost / $tot, 3) } else { 100.0 }   # iperf rounds its own figure
                    Note ("{0} at {1}b/s" -f $dir.name, $rate) ($lossPct -le 1.0) ("{0:N1} Mbit/s, {1}/{2} lost ({3}%)" -f $mbps, $m.Groups[3].Value, $m.Groups[4].Value, $lossPct)
                } else {
                    Note ("{0} at {1}b/s" -f $dir.name, $rate) $false 'no loss report from iperf'
                }
            }
        } else {
            $script:blocked += 'iperf -u (no iperf 2 binary: use -Iperf, RTLNET_IPERF or PATH)'
        }
    }

    # Forced 10 Mb/s from the CLI, then auto again.
    if ($Speed -ne 10) {
        [void](Send-Cli $sp 'configure terminal'); [void](Send-Cli $sp 'interface eth0'); [void](Send-Cli $sp 'speed 10'); [void](Send-Cli $sp 'end')
        [void](Board-Checks $sp 10 '[10]')
        [void](Send-Cli $sp 'configure terminal'); [void](Send-Cli $sp 'interface eth0'); [void](Send-Cli $sp 'speed auto'); [void](Send-Cli $sp 'end')
        $o = Wait-Link $sp $Speed
        Note "speed auto restores $Speed Mb/s" ($o -match "eth0 is up, $Speed Mb/s") ''
    }
    [void](Send-Cli $sp 'disable')
} finally {
    $sp.Close()
}

$text = $script:log.ToString() -replace "`r`n", "`n" -replace "`r", ''
Set-Content -LiteralPath $TranscriptPath -Value $text -Encoding ascii
foreach ($r in $script:results) {
    Write-Output ("  {0,-4} {1,-48} {2}" -f ($(if ($r.Ok) { 'ok' } else { 'FAIL' }), $r.Name, $r.Detail))
}
foreach ($b in $script:blocked) { Write-Output "  BLOCKED $b" }
$failed = @($script:results | Where-Object { -not $_.Ok }).Count
$total = $script:results.Count
Write-Output "Transcript: $TranscriptPath"
if ($failed -eq 0 -and $total -gt 0) {
    Write-Output ("NET_TEST: PASS {0}/{0}{1}" -f $total, $(if ($script:blocked.Count) { ", $($script:blocked.Count) host check(s) BLOCKED" } else { '' }))
    exit 0
}
Write-Output "NET_TEST: FAIL $failed/$total"
exit 1
