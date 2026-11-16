<#
-------------------------------------------------------------------------------
File: firewall_test.ps1
Purpose: hardware test of the CPU-path firewall of the Ethernet demo firmware (classifier firewall enable|disable),
  board independent.
Overview:
  * Needs the console (-Port) to change the firmware configuration and the PC adapter (-Nic): every socket binds to the
    adapter's address, ping leaves from it.
  * Step a, firewall off: a TCP connect to a closed port (23, the echo server is on 7) is refused with a RST within
    -RefuseMs; a UDP datagram to a closed port is answered by lwIP with an ICMP port unreachable (the contrast to step b).
  * Step b, `iperf tcp disable`, `classifier firewall enable`: `show classifier` shows the Firewall block enabled; the TCP
    echo server on port 7 echoes a line; TCP connects to 5001 and to 23 get no answer in -TimeoutMs (no RST, no refusal);
    a UDP datagram to a closed port gets no ICMP port unreachable; ping is answered by the hardware responder; the drop
    count of the Firewall block rises across the step.
  * Step c, `tcp echo port 23`: echo works on 23, a connect to 7 gets no answer.
  * Step d, restore (always runs, also after a failed step or an exception): `tcp echo port 7`, `iperf tcp enable`,
    `classifier firewall disable`; the echo server on 7 echoes a line, port 5001 accepts a connection, 23 is refused again.
  * One verdict line per step (firewall_test: step <x>: PASS|FAIL), then the rows and the final line.
  * The board address comes from the console (`show ip`) unless -Board is given.
  * Final line: FIREWALL_TEST: PASS n/n or FIREWALL_TEST: FAIL f/n.
  * Written 11-16-2026; not yet run on a board.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/firewall_test.ps1 -Port <COM port> -Nic <PC adapter> [-Board <ip>] [-EchoPort 7] [-AltPort 23] [-IperfPort 5001] [-TimeoutMs 4000] [-RefuseMs 2000] [-OutDir <dir>] [-Csv <file>]
Revision: 11-16-2026
  * 11-16-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [Parameter(Mandatory = $true)][string]$Nic,
    [string]$Board = '',
    [int]$EchoPort = 7,
    [int]$AltPort = 23,
    [int]$IperfPort = 5001,
    [int]$TimeoutMs = 4000,
    [int]$RefuseMs = 2000,
    [string]$OutDir = '',
    [string]$Csv = ''
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'eth_test_common.ps1')
Initialize-EthTest 'FIREWALL_TEST' $OutDir $Csv
$s = Initialize-EthSession $Port $Nic $Board
$sp = $s.Sp
$board = $s.Board
$src = $s.Nic.Ip
$udpPort = 40000
if (-not $sp) { Write-Output 'FIREWALL_TEST: FAIL the console is needed to change the firewall'; exit 1 }
Write-Output "firewall_test: board $board from $src"

# TCP connect from the adapter's address. Returns @{ Result = connected|refused|timeout|error:<code>; Ms; Sock } (Sock only when connected).
function Connect-FwTcp([string]$Remote, [int]$RemotePort, [int]$WaitMs) {
    $sock = New-Object System.Net.Sockets.Socket -ArgumentList @([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Tcp)
    $sock.Bind((New-Object System.Net.IPEndPoint -ArgumentList @([System.Net.IPAddress]::Parse($src), 0)))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ar = $sock.BeginConnect((New-Object System.Net.IPEndPoint -ArgumentList @([System.Net.IPAddress]::Parse($Remote), $RemotePort)), $null, $null)
    $done = $ar.AsyncWaitHandle.WaitOne($WaitMs)
    $ms = [int]$sw.ElapsedMilliseconds
    if (-not $done) {
        $sock.Close()
        return [pscustomobject]@{ Result = 'timeout'; Ms = $ms; Sock = $null }
    }
    try {
        $sock.EndConnect($ar)
        return [pscustomobject]@{ Result = 'connected'; Ms = $ms; Sock = $sock }
    } catch [System.Net.Sockets.SocketException] {
        $code = $_.Exception.SocketErrorCode
        $sock.Close()
        $res = if ($code -eq [System.Net.Sockets.SocketError]::ConnectionRefused) { 'refused' } else { "error:$code" }
        return [pscustomobject]@{ Result = $res; Ms = $ms; Sock = $null }
    }
}

# Connect, send one line, read it back, close. Returns @{ Result; Echoed } (Result as Connect-FwTcp, or echo|noecho|mismatch).
function Test-FwEcho([int]$RemotePort) {
    $c = Connect-FwTcp $board $RemotePort $TimeoutMs
    if ($c.Result -ne 'connected') { return [pscustomobject]@{ Result = $c.Result; Echoed = '' } }
    $sock = $c.Sock
    $line = "firewall test line $RemotePort`n"
    $want = [System.Text.Encoding]::ASCII.GetBytes($line)
    $got = New-Object System.Collections.Generic.List[byte]
    try {
        $sock.ReceiveTimeout = 3000
        [void]$sock.Send($want)
        $buf = New-Object byte[] 256
        while ($got.Count -lt $want.Length) {
            $n = $sock.Receive($buf)
            if ($n -le 0) { break }
            for ($i = 0; $i -lt $n; $i++) { $got.Add($buf[$i]) }
        }
    } catch { }
    try { $sock.Close() } catch { }
    $text = [System.Text.Encoding]::ASCII.GetString($got.ToArray())
    $res = if ($text -eq $line) { 'echo' } elseif ($got.Count -eq 0) { 'noecho' } else { 'mismatch' }
    return [pscustomobject]@{ Result = $res; Echoed = $text.Trim() }
}

# One UDP datagram to a closed port on a connected socket, so that an ICMP port unreachable surfaces as a reset.
# Returns unreachable | silent | reply | error:<code>.
function Test-FwUdpClosed([int]$RemotePort) {
    $sock = New-Object System.Net.Sockets.Socket -ArgumentList @([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
    try {
        $sock.Bind((New-Object System.Net.IPEndPoint -ArgumentList @([System.Net.IPAddress]::Parse($src), 0)))
        $sock.Connect((New-Object System.Net.IPEndPoint -ArgumentList @([System.Net.IPAddress]::Parse($board), $RemotePort)))
        $sock.ReceiveTimeout = $TimeoutMs
        $buf = New-Object byte[] 64
        [void]$sock.Send([System.Text.Encoding]::ASCII.GetBytes('firewall udp probe'))
        try {
            [void]$sock.Receive($buf)
            return 'reply'
        } catch [System.Net.Sockets.SocketException] {
            $code = $_.Exception.SocketErrorCode
            if ($code -eq [System.Net.Sockets.SocketError]::ConnectionReset) { return 'unreachable' }
            if ($code -eq [System.Net.Sockets.SocketError]::TimedOut) { return 'silent' }
            return "error:$code"
        }
    } catch {
        return "error:$($_.Exception.Message)"
    } finally {
        $sock.Close()
    }
}

# Configuration commands in configuration mode; returns the console text (a line with % reports a refused command).
function Set-FwConfig([string[]]$Commands) {
    $text = ''
    [void](Enter-EthPriv $sp)
    $text += Send-EthCli $sp 'configure terminal'
    foreach ($cmd in $Commands) { $text += Send-EthCli $sp $cmd 8000 }
    [void](Enter-EthPriv $sp)
    return $text
}

# The Firewall block of show classifier: @{ Enabled; Dropped } (Dropped -1 when the line is absent).
function Get-FwBlock {
    [void](Enter-EthPriv $sp)
    $o = Send-EthCli $sp 'show classifier' 8000
    $en = ($o -match 'Firewall \(CPU path\)') -and ($o -match 'State\s+: enabled \(default deny\)')
    $d = -1
    if ($o -match 'Dropped\s+: (\d+) frames \(not ARP and not allowed\)') { $d = [int]$Matches[1] }
    return [pscustomobject]@{ Enabled = $en; Dropped = $d }
}

# Verdict line of one step from the rows added since $first.
function Write-FwStep([string]$Name, [int]$First) {
    $mine = @($script:EthRows | Select-Object -Skip $First)
    $bad = @($mine | Where-Object { $_.Verdict -ne 'PASS' }).Count
    Write-Output ("firewall_test: step {0}: {1} ({2} checks, {3} failed)" -f $Name, $(if ($bad -eq 0 -and $mine.Count -gt 0) { 'PASS' } else { 'FAIL' }), $mine.Count, $bad)
}

try {
    # ---- Step a: firewall off, a closed TCP port is refused.
    $first = $script:EthRows.Count
    $o = Set-FwConfig @("tcp echo port $EchoPort", 'iperf tcp enable', 'classifier firewall disable')
    Add-EthRow 'a: configuration accepted (no % line)' '' '' ($o -notmatch '(?m)^\s*%')
    Start-Sleep -Milliseconds 1000
    $blk = Get-FwBlock
    Add-EthRow 'a: show classifier: firewall disabled' '' '' (-not $blk.Enabled)
    $e = Test-FwEcho $EchoPort
    Add-EthRow "a: TCP echo on port $EchoPort works" $e.Result '' ($e.Result -eq 'echo')
    $c = Connect-FwTcp $board $AltPort $TimeoutMs
    if ($c.Sock) { $c.Sock.Close() }
    Add-EthRow "a: TCP connect to closed port $AltPort refused" ("{0} in {1}" -f $c.Result, $c.Ms) 'ms' (($c.Result -eq 'refused') -and ($c.Ms -le $RefuseMs))
    $u = Test-FwUdpClosed $udpPort
    Add-EthRow "a: UDP to closed port $udpPort answered by ICMP unreachable" $u '' ($u -eq 'unreachable')
    Write-FwStep 'a' $first

    # ---- Step b: firewall on, echo on 7 only.
    $first = $script:EthRows.Count
    $o = Set-FwConfig @('iperf tcp disable', 'classifier firewall enable')
    Add-EthRow 'b: firewall enable accepted (no % line)' '' '' ($o -notmatch '(?m)^\s*%')
    Start-Sleep -Milliseconds 1000
    $blk0 = Get-FwBlock
    Add-EthRow 'b: show classifier: firewall enabled (default deny)' '' '' $blk0.Enabled
    $e = Test-FwEcho $EchoPort
    Add-EthRow "b: TCP echo on port $EchoPort works" $e.Result '' ($e.Result -eq 'echo')
    $c = Connect-FwTcp $board $IperfPort $TimeoutMs
    if ($c.Sock) { $c.Sock.Close() }
    Add-EthRow "b: TCP connect to $IperfPort times out" ("{0} in {1}" -f $c.Result, $c.Ms) 'ms' ($c.Result -eq 'timeout')
    $c = Connect-FwTcp $board $AltPort $TimeoutMs
    if ($c.Sock) { $c.Sock.Close() }
    Add-EthRow "b: TCP connect to $AltPort times out (no RST)" ("{0} in {1}" -f $c.Result, $c.Ms) 'ms' ($c.Result -eq 'timeout')
    $u = Test-FwUdpClosed $udpPort
    Add-EthRow "b: UDP to closed port $udpPort, no ICMP unreachable" $u '' ($u -eq 'silent')
    $p = Invoke-EthPing $board $src 4 32
    Add-EthRow 'b: ping answered by the hardware responder' $p.Lost 'of 4 lost' ($p.Lost -eq 0)
    $blk1 = Get-FwBlock
    Add-EthRow 'b: firewall drop count rises' ("{0} -> {1}" -f $blk0.Dropped, $blk1.Dropped) 'frames' (($blk0.Dropped -ge 0) -and ($blk1.Dropped -gt $blk0.Dropped))
    Write-FwStep 'b' $first

    # ---- Step c: echo moved to port 23 while the firewall stays on.
    $first = $script:EthRows.Count
    $o = Set-FwConfig @("tcp echo port $AltPort")
    Add-EthRow 'c: tcp echo port change accepted (no % line)' '' '' ($o -notmatch '(?m)^\s*%')
    Start-Sleep -Milliseconds 1000
    $e = Test-FwEcho $AltPort
    Add-EthRow "c: TCP echo on port $AltPort works" $e.Result '' ($e.Result -eq 'echo')
    $c = Connect-FwTcp $board $EchoPort $TimeoutMs
    if ($c.Sock) { $c.Sock.Close() }
    Add-EthRow "c: TCP connect to old port $EchoPort times out" ("{0} in {1}" -f $c.Result, $c.Ms) 'ms' ($c.Result -eq 'timeout')
    Write-FwStep 'c' $first
}
catch {
    Add-EthRow 'exception during steps a to c' ($_.Exception.Message -replace '[\r\n]+', ' ') '' $false
    Write-Output "firewall_test: step aborted: $($_.Exception.Message)"
}
finally {
    # ---- Step d: restore the board's configuration (always).
    $first = $script:EthRows.Count
    try {
        $o = Set-FwConfig @("tcp echo port $EchoPort", 'iperf tcp enable', 'classifier firewall disable')
        Add-EthRow 'd: restore commands accepted (no % line)' '' '' ($o -notmatch '(?m)^\s*%')
        Start-Sleep -Milliseconds 1500
        $blk = Get-FwBlock
        Add-EthRow 'd: show classifier: firewall disabled' '' '' (-not $blk.Enabled)
        $e = Test-FwEcho $EchoPort
        Add-EthRow "d: TCP echo on port $EchoPort works" $e.Result '' ($e.Result -eq 'echo')
        $c = Connect-FwTcp $board $IperfPort $TimeoutMs
        if ($c.Sock) { $c.Sock.Close() }
        if ($c.Result -ne 'connected') {
            Start-Sleep -Milliseconds 1000
            $c = Connect-FwTcp $board $IperfPort $TimeoutMs
            if ($c.Sock) { $c.Sock.Close() }
        }
        Add-EthRow "d: TCP connect to $IperfPort accepted" ("{0} in {1}" -f $c.Result, $c.Ms) 'ms' ($c.Result -eq 'connected')
        $c = Connect-FwTcp $board $AltPort $TimeoutMs
        if ($c.Sock) { $c.Sock.Close() }
        Add-EthRow "d: TCP connect to closed port $AltPort refused" ("{0} in {1}" -f $c.Result, $c.Ms) 'ms' ($c.Result -eq 'refused')
    } catch {
        Add-EthRow 'exception during the restore' ($_.Exception.Message -replace '[\r\n]+', ' ') '' $false
    }
    Write-FwStep 'd' $first
    try { $sp.Close() } catch { }
}
Complete-EthTest
