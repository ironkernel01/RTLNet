<#
-------------------------------------------------------------------------------
File: flood_test.ps1
Purpose: protection profile test of the Ethernet demo on the board: the classifier on the CPU path limits broadcast, UDP,
  ARP and ICMP traffic while TCP, ping and the console keep working. Board independent.
Overview:
  * The board address comes from the console (`show ip`) unless -Board is given; every packet leaves from the PC
    adapter's address (-Nic), so only that adapter carries the load.
  * Load (eth_flood_test.py, plain sockets and the Windows ICMP API, no Npcap or Scapy needed): for -Seconds seconds UDP
    broadcasts to the subnet broadcast address (-BroadcastRate per second), UDP multicast (-MulticastRate), ARP requests
    (UDP to unused subnet addresses, -ArpRate), ICMP echo requests to the subnet broadcast address and to the board
    (-IcmpRate); at the same time one TCP echo connection to port 7 exchanges 1460-byte blocks, compared byte for byte.
  * While the load runs the script (a) keeps asking the console `show classifier` and `show system` and times each
    answer, (b) pings the board in short batches, and compares the board's uptime before and after.
  * Pass criteria (each is a table row): the TCP echo had no error and moved data; every console answer arrived within
    -ConsoleBoundMs; the ping loss stays within -MaxPingLossPct; the uptime advanced by about the test time (the board did
    not reset); the UDP class drop counter rose (the broadcast load is far above its limit); the multicast frames did not
    reach the CPU path (they are not counted in any class); the profile is still installed. The ARP and ICMP class
    counters are reported; they must not fall, and with -RequireArpIcmp they must rise.
  * Limitation: raw Ethernet frames need Npcap or Scapy (checked, not used). With ordinary sockets the "broadcast" class
    of the profile (broadcast frames that are not ARP, ICMP or UDP) sees nothing, UDP broadcasts count in the "udp" class,
    ICMP is limited to echo requests, and the ARP rate is bounded by the PC's own ARP behaviour (one request per unused
    address and attempt).
  * Final line: FLOOD_TEST: PASS n/n or FLOOD_TEST: FAIL f/n.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/flood_test.ps1 -Port <COM port> -Nic <PC adapter> `
    [-Board <ip>] [-Seconds 20] [-BroadcastRate 2000] [-MulticastRate 500] [-ArpRate 200] [-IcmpRate 300] `
    [-ConsoleBoundMs 3000] [-MaxPingLossPct 20] [-RequireArpIcmp] [-OutDir <dir>] [-Csv <file>]
Revision: 11-14-2026
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [Parameter(Mandatory = $true)][string]$Nic,
    [string]$Board = '',
    [int]$Seconds = 20,
    [int]$BroadcastRate = 2000,
    [int]$MulticastRate = 500,
    [int]$ArpRate = 200,
    [int]$IcmpRate = 300,
    [int]$ConsoleBoundMs = 3000,
    [int]$MaxPingLossPct = 20,
    [switch]$RequireArpIcmp,
    [string]$OutDir = '',
    [string]$Csv = ''
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'eth_test_common.ps1')
Initialize-EthTest 'FLOOD_TEST' $OutDir $Csv
$s = Initialize-EthSession $Port $Nic $Board
if (-not $s.Sp) { Write-Output 'FLOOD_TEST: FAIL the console is needed (-Port): the test reads the classifier counters'; exit 1 }
$sp = $s.Sp
$board = $s.Board
$src = $s.Nic.Ip

# Subnet of the adapter: network address, prefix length and broadcast address.
$addr = Get-NetIPAddress -IPAddress $src -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
$prefix = if ($addr) { [int]$addr.PrefixLength } else { 24 }
$ipBytes = ([System.Net.IPAddress]::Parse($src)).GetAddressBytes()
[array]::Reverse($ipBytes)
$ipNum = [System.BitConverter]::ToUInt32($ipBytes, 0)
$maskNum = if ($prefix -eq 0) { [uint32]0 } else { [uint32]([uint64]4294967295 -band ([uint64]4294967295 -shl (32 - $prefix))) }
$netNum = [uint32]($ipNum -band $maskNum)
$bcNum = [uint32]($netNum -bor ([uint32]4294967295 -bxor $maskNum))
function ConvertTo-Dotted([uint32]$n) { return ('{0}.{1}.{2}.{3}' -f (($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255)) }
$net = ConvertTo-Dotted $netNum
$bcast = ConvertTo-Dotted $bcNum

# What can this PC send? Raw frames need Npcap (wpcap.dll) and Scapy; report it, use plain sockets either way.
$py = Resolve-RtlnetPython
$npcap = (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\Npcap\wpcap.dll')) -or (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\wpcap.dll'))
$scapy = $false
& $py -I -c 'import scapy' 2>$null
if ($LASTEXITCODE -eq 0) { $scapy = $true }
Write-Output ("flood_test: board {0} from {1}/{2} (broadcast {3}); raw frames: Npcap {4}, Scapy {5} - not used, plain sockets only" -f $board, $src, $prefix, $bcast, $npcap, $scapy)

# Parse "show classifier" (profile state and one row per class) and "show system" (uptime in ms).
function Get-FloodClassifier([string]$text) {
    $r = [ordered]@{ Installed = ($text -match 'protection profile installed'); Classes = @{} }
    foreach ($m in [regex]::Matches($text, '(?m)^\s+(broadcast|udp|arp|icmp)\s+(\d+) / +(\d+) ms +(\d+) +(\d+) +(\d+)')) {
        $r.Classes[$m.Groups[1].Value] = [pscustomobject]@{ Limit = [int64]$m.Groups[2].Value; Window = [int64]$m.Groups[3].Value;
            Seen = [int64]$m.Groups[4].Value; Passed = [int64]$m.Groups[5].Value; Dropped = [int64]$m.Groups[6].Value }
    }
    return $r
}
function Get-FloodUptimeMs([string]$text) {
    $m = [regex]::Match($text, 'Uptime\s+:.*\((\d+) ms since reset release')
    if ($m.Success) { return [int64]$m.Groups[1].Value }
    return -1
}
function Get-FloodFiltered([string]$text) {
    $m = [regex]::Match($text, 'Protocol\s+: ingress (\d+), filtered (\d+)')
    if ($m.Success) { return [int64]$m.Groups[2].Value }
    return -1
}
function Measure-FloodCli($sp, [string]$cmd) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $o = Send-EthCli $sp $cmd ($ConsoleBoundMs * 3)
    $sw.Stop()
    $ok = ($o -match 'rtlnet#\s*$') -or ($o -match 'rtlnet>\s*$')
    return [pscustomobject]@{ Text = $o; Ms = [int]$sw.ElapsedMilliseconds; Ok = $ok }
}

# Baseline.
$c0 = Measure-FloodCli $sp 'show classifier'
$u0t = Measure-FloodCli $sp 'show system'
$base = Get-FloodClassifier $c0.Text
$up0 = Get-FloodUptimeMs $u0t.Text
if (-not $base.Installed -or $base.Classes.Count -ne 4) {
    Add-EthRow 'show classifier: protection profile installed, four classes' $base.Installed '' $false
    Complete-EthTest
}
Add-EthRow 'show classifier before: profile installed, four classes' 'yes' '' $true
$k0 = Measure-FloodCli $sp 'show counters'
$filt0 = Get-FloodFiltered $k0.Text

# Start the load in the background.
$pyScript = Join-Path $PSScriptRoot 'eth_flood_test.py'
$outFile = Join-Path $script:EthOutDir 'flood_load_output.txt'
$errFile = Join-Path $script:EthOutDir 'flood_load_error.txt'
$pyArgs = @('-I', ('"{0}"' -f $pyScript), $board, '--bind', $src, '--net', $net, '--prefix', "$prefix", '--bcast', $bcast,
    '--seconds', "$Seconds", '--bcast-rate', "$BroadcastRate", '--mcast-rate', "$MulticastRate", '--arp-rate', "$ArpRate", '--icmp-rate', "$IcmpRate")
$proc = Start-Process -FilePath $py -ArgumentList $pyArgs -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$maxCliMs = 0
$cliBad = 0
$cliN = 0
$pingSent = 0
$pingLost = 0
$last = $null
$lastUp = -1
$upBackwards = 0
while (-not $proc.HasExited -and $sw.Elapsed.TotalSeconds -lt ($Seconds + 30)) {
    $c = Measure-FloodCli $sp 'show classifier'
    $cliN++
    if ($c.Ms -gt $maxCliMs) { $maxCliMs = $c.Ms }
    if (-not $c.Ok -or $c.Ms -gt $ConsoleBoundMs) { $cliBad++ }
    $parsed = Get-FloodClassifier $c.Text
    if ($parsed.Classes.Count -eq 4) { $last = $parsed }
    $u = Measure-FloodCli $sp 'show system'
    $cliN++
    if ($u.Ms -gt $maxCliMs) { $maxCliMs = $u.Ms }
    if (-not $u.Ok -or $u.Ms -gt $ConsoleBoundMs) { $cliBad++ }
    $up = Get-FloodUptimeMs $u.Text
    if ($up -ge 0) { if ($lastUp -ge 0 -and $up -lt $lastUp) { $upBackwards++ }; $lastUp = $up }
    $p = Invoke-EthPing $board $src 3 32
    $pingSent += $p.Sent
    if ($p.Lost -ge 0) { $pingLost += $p.Lost } else { $pingLost += $p.Sent }
}
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force; Add-EthRow 'load generator finished in time' 'no' '' $false }
$proc.WaitForExit()
$loadText = ''
if (Test-Path -LiteralPath $outFile) { $loadText = (Get-Content -LiteralPath $outFile -Raw) }
if (Test-Path -LiteralPath $errFile) { $loadText += (Get-Content -LiteralPath $errFile -Raw) }
Write-EthLog $loadText
$done = [regex]::Match($loadText, 'ETH_FLOOD: DONE tcp_errors=(\d+) tcp_bytes=(\d+) tcp_max_rtt_ms=([\d.]+) tcp_rounds=(\d+) sent_udp_bcast=(\d+) sent_mcast=(\d+) sent_arp_dst=(\d+) sent_icmp_bcast=(\d+) sent_icmp_board=(\d+)')

# After the load: let the last frames drain, then read the counters and the uptime again.
Start-Sleep -Milliseconds 500
$c1 = Measure-FloodCli $sp 'show classifier'
$u1 = Measure-FloodCli $sp 'show system'
$k1 = Measure-FloodCli $sp 'show counters'
$filt1 = Get-FloodFiltered $k1.Text
$after = Get-FloodClassifier $c1.Text
$up1 = Get-FloodUptimeMs $u1.Text
$elapsedMs = [int64]$sw.ElapsedMilliseconds

# Results.
if ($done.Success) {
    $tcpErr = [int]$done.Groups[1].Value
    Add-EthRow 'TCP echo during the load: errors' $tcpErr '' ($tcpErr -eq 0)
    Add-EthRow 'TCP echo during the load: bytes echoed byte-exact' $done.Groups[2].Value 'bytes' ([int64]$done.Groups[2].Value -gt 0)
    Add-EthRow 'TCP echo during the load: slowest 1460-byte round' $done.Groups[3].Value 'ms' $true
    Add-EthRow 'load sent: udp broadcast / multicast / arp destinations / icmp broadcast / icmp board' ("{0}/{1}/{2}/{3}/{4}" -f $done.Groups[5].Value, $done.Groups[6].Value, $done.Groups[7].Value, $done.Groups[8].Value, $done.Groups[9].Value) 'datagrams' $true
} else {
    Add-EthRow 'load generator reported DONE' 'no' '' $false
}
Add-EthRow "console answers within $ConsoleBoundMs ms (worst $maxCliMs ms)" ("{0} late or missing of {1}" -f $cliBad, $cliN) '' (($cliBad -eq 0) -and ($cliN -gt 0))
$lossPct = if ($pingSent -gt 0) { [math]::Round(100.0 * $pingLost / $pingSent, 1) } else { 100.0 }
Add-EthRow "ping during the load: loss (limit $MaxPingLossPct %)" ("{0} of {1} = {2} %" -f $pingLost, $pingSent, $lossPct) '' (($pingSent -gt 0) -and ($lossPct -le $MaxPingLossPct))
$upDelta = $up1 - $up0
Add-EthRow 'board uptime advanced by about the test time (no reset)' ("{0} ms in {1} ms" -f $upDelta, $elapsedMs) '' (($up0 -ge 0) -and ($up1 -ge 0) -and ($upBackwards -eq 0) -and ($upDelta -ge ($Seconds * 800)))
Add-EthRow 'show classifier after: profile still installed' $after.Installed '' ($after.Installed -and $after.Classes.Count -eq 4)
if ($after.Classes.Count -eq 4) {
    foreach ($name in @('broadcast', 'udp', 'arp', 'icmp')) {
        $b = $base.Classes[$name]; $a = $after.Classes[$name]
        $dSeen = $a.Seen - $b.Seen; $dDrop = $a.Dropped - $b.Dropped; $dPass = $a.Passed - $b.Passed
        $detail = "seen +$dSeen, passed +$dPass, dropped +$dDrop (limit $($a.Limit) per $($a.Window) ms)"
        switch ($name) {
            'udp'  { Add-EthRow 'class udp: drop counter rose (broadcast load far above the limit)' $detail '' ($dDrop -gt 0) }
            'arp'  { Add-EthRow 'class arp: counters (ARP requests of the PC to unused addresses)' $detail '' (($dSeen -ge 0) -and ((-not $RequireArpIcmp) -or ($dSeen -gt 0))) }
            'icmp' { Add-EthRow 'class icmp: counters (echo requests to the subnet broadcast address)' $detail '' (($dSeen -ge 0) -and ((-not $RequireArpIcmp) -or ($dSeen -gt 0))) }
            default { Add-EthRow 'class broadcast: counters (non-ARP, non-ICMP, non-UDP broadcasts: none with plain sockets)' $detail '' ($dSeen -ge 0) }
        }
    }
    # Multicast never reaches the CPU path: the board's ingress filter discards it and counts it as filtered.
}
if ($done.Success -and $filt0 -ge 0 -and $filt1 -ge 0) {
    $mc = [int64]$done.Groups[6].Value
    Add-EthRow 'multicast load discarded by the ingress filter (counted as filtered, never in a class)' ("filtered +{0} for {1} sent" -f ($filt1 - $filt0), $mc) '' (($mc -eq 0) -or (($filt1 - $filt0) -gt ($mc / 4)))
}
$sp.Close()
Complete-EthTest
