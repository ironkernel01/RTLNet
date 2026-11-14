<#
-------------------------------------------------------------------------------
File: flood_test.ps1
Purpose: protection profile test of the Ethernet demo on the board: the classifier on the CPU path limits UDP, ARP and
  ICMP traffic (and discards multicast at the ingress) while the console, ping and TCP keep working. Board independent.
Overview:
  * Normal sockets only (Python standard library, iphlpapi through ctypes), no administrator rights, nothing to install. The board address comes from the console (`show ip`) unless -Board is given (it is a DHCP lease); every
    packet leaves from the PC adapter's address (-Nic). The board lock is taken like in the other test scripts.
  * One flood per kind (-Kinds, default all), each -Seconds long at -Rate per second, run by eth_flood_test.py while one
    TCP echo connection exchanges data: udp-closed (UDP to the board, port 9), udp-echo (port 7, hardware echo),
    udp-bcast-lim (255.255.255.255), udp-bcast-net (subnet broadcast), mcast (239.255.42.42, a group the board never
    joined), icmp-board, icmp-bcast (echo requests to the subnet broadcast), arp (iphlpapi SendARP).
  * During each flood the script asks the console `show classifier` and `show system` in a loop (each answer timed) and
    pings the board in short batches; before and after it reads the per-class counters (seen, passed, dropped) and the
    protocol's `filtered` counter.
  * Pass criteria per flood (each a table row): the generator sent frames; the TCP echo had no error and moved data; every
    console answer within -ConsoleBoundMs; ping loss within -MaxPingLossPct; the board's uptime advanced by about the flood
    time (no reset); the profile is still installed; the policed class shows drops where the rate is above its policer
    (udp-closed, udp-bcast-lim, udp-bcast-net, icmp-bcast); the other classes drop at most -OtherDropTolerance frames;
    mcast: no class counts it and the `filtered` counter rises. udp-echo, icmp-board and arp are reported, not required
    (see below), arp is required to rise only with -RequireArp.
  * What the kinds cannot do: a frame that is not UDP, ICMP or ARP cannot be sent, so the `broadcast` class (broadcast that
    is not ARP, ICMP or UDP) is never exercised and UDP broadcasts count in the `udp` class. udp-echo and icmp-board are
    answered by hardware and normally do not reach the CPU path. SendARP blocks per call (until the request times out), so
    the ARP rate is bounded by the thread count; whether a call puts a request on the wire is not verified by this script,
    so the arp row is reported, not required.
  * Final line: FLOOD_TEST: PASS n/n or FLOOD_TEST: FAIL f/n. Output (transcript, generator output) goes to test/out/.
Usage (example addresses 192.0.2.x):
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/flood_test.ps1 -Port <COM port> -Nic <PC adapter> `
    [-Board 192.0.2.50] [-Kinds udp-closed,udp-bcast-net,mcast,icmp-bcast] [-Seconds 10] [-Rate 1000] [-ConsoleBoundMs 3000] `
    [-MaxPingLossPct 20] [-OtherDropTolerance 5] [-RequireArp] [-OutDir <dir>] [-Csv <file>]
Revision: 11-14-2026
  * 11-14-2026: initial version; normal sockets only.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [Parameter(Mandatory = $true)][string]$Nic,
    [string]$Board = '',
    [string[]]$Kinds = @('udp-closed', 'udp-echo', 'udp-bcast-lim', 'udp-bcast-net', 'mcast', 'icmp-board', 'icmp-bcast', 'arp'),
    [int]$Seconds = 10,
    [int]$Rate = 1000,
    [int]$ConsoleBoundMs = 3000,
    [int]$MaxPingLossPct = 20,
    [int]$OtherDropTolerance = 5,
    [switch]$RequireArp,
    [int]$IcmpThreads = 0,
    [string]$OutDir = '',
    [string]$Csv = ''
)
$ErrorActionPreference = 'Continue'
# powershell -File delivers '-Kinds a,b' as one string: split on commas.
$Kinds = @($Kinds | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
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
$py = Resolve-RtlnetPython
$pyScript = Join-Path $PSScriptRoot 'eth_flood_test.py'
Write-Output ("flood_test: board {0} from {1}/{2} (subnet broadcast {3}), kinds: {4}" -f $board, $src, $prefix, $bcast, ($Kinds -join ','))

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
function Get-FloodState($sp) {
    $c = Measure-FloodCli $sp 'show classifier'
    $k = Measure-FloodCli $sp 'show counters'
    $u = Measure-FloodCli $sp 'show system'
    return [pscustomobject]@{ Cls = (Get-FloodClassifier $c.Text); Filtered = (Get-FloodFiltered $k.Text); UpMs = (Get-FloodUptimeMs $u.Text) }
}

# Policed class per kind ('' = none) and whether drops are required.
$policed = @{ 'udp-closed' = 'udp'; 'udp-bcast-lim' = 'udp'; 'udp-bcast-net' = 'udp'; 'icmp-bcast' = 'icmp' }
$reported = @{ 'udp-echo' = 'udp'; 'icmp-board' = 'icmp'; 'arp' = 'arp' }

$first = Measure-FloodCli $sp 'show classifier'
if (-not (Get-FloodClassifier $first.Text).Installed) {
    Add-EthRow 'show classifier: protection profile installed' 'no' '' $false
    $sp.Close()
    Complete-EthTest
}

foreach ($kind in $Kinds) {
    Write-Output "flood_test: kind $kind"
    $before = Get-FloodState $sp
    $outFile = Join-Path $script:EthOutDir ("flood_{0}_output.txt" -f $kind)
    $errFile = Join-Path $script:EthOutDir ("flood_{0}_error.txt" -f $kind)
    $pyArgs = @('-I', ('"{0}"' -f $pyScript), $board, '--bind', $src, '--net', $net, '--prefix', "$prefix", '--bcast', $bcast,
        '--kind', $kind, '--rate', "$Rate", '--seconds', "$Seconds")
    if ($IcmpThreads -gt 0) { $pyArgs += @('--icmp-threads', "$IcmpThreads") }
    $proc = Start-Process -FilePath $py -ArgumentList $pyArgs -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $maxCliMs = 0; $cliBad = 0; $cliN = 0; $pingSent = 0; $pingLost = 0; $lastUp = -1; $upBackwards = 0
    while (-not $proc.HasExited -and $sw.Elapsed.TotalSeconds -lt ($Seconds + 40)) {
        foreach ($cmd in @('show classifier', 'show system')) {
            $c = Measure-FloodCli $sp $cmd
            $cliN++
            if ($c.Ms -gt $maxCliMs) { $maxCliMs = $c.Ms }
            if (-not $c.Ok -or $c.Ms -gt $ConsoleBoundMs) { $cliBad++ }
            if ($cmd -eq 'show system') {
                $up = Get-FloodUptimeMs $c.Text
                if ($up -ge 0) { if ($lastUp -ge 0 -and $up -lt $lastUp) { $upBackwards++ }; $lastUp = $up }
            }
        }
        $p = Invoke-EthPing $board $src 3 32
        $pingSent += $p.Sent
        if ($p.Lost -ge 0) { $pingLost += $p.Lost } else { $pingLost += $p.Sent }
    }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force; Add-EthRow "${kind}: generator finished in time" 'no' '' $false }
    $proc.WaitForExit()
    $loadText = ''
    if (Test-Path -LiteralPath $outFile) { $loadText = (Get-Content -LiteralPath $outFile -Raw) }
    if (Test-Path -LiteralPath $errFile) { $loadText += (Get-Content -LiteralPath $errFile -Raw) }
    Write-EthLog $loadText
    $done = [regex]::Match($loadText, 'ETH_FLOOD: DONE kind=\S+ sent=(\d+) seconds=([\d.]+) tcp_errors=(\d+) tcp_bytes=(\d+) tcp_max_rtt_ms=([\d.]+)')
    Start-Sleep -Milliseconds 500
    $after = Get-FloodState $sp
    $elapsedMs = [int64]$sw.ElapsedMilliseconds

    if ($done.Success) {
        $sent = [int64]$done.Groups[1].Value
        Add-EthRow "${kind}: frames actually sent by the generator" $sent 'frames' ($sent -gt 0)
        Add-EthRow "${kind}: TCP echo during the flood: errors" $done.Groups[3].Value '' ([int]$done.Groups[3].Value -eq 0)
        Add-EthRow "${kind}: TCP echo during the flood: bytes echoed byte-exact (slowest round $($done.Groups[5].Value) ms)" $done.Groups[4].Value 'bytes' ([int64]$done.Groups[4].Value -gt 0)
    } else {
        Add-EthRow "${kind}: generator reported DONE" 'no' '' $false
    }
    Add-EthRow "${kind}: console answers within $ConsoleBoundMs ms (worst $maxCliMs ms)" ("{0} late or missing of {1}" -f $cliBad, $cliN) '' (($cliBad -eq 0) -and ($cliN -gt 0))
    $lossPct = if ($pingSent -gt 0) { [math]::Round(100.0 * $pingLost / $pingSent, 1) } else { 100.0 }
    Add-EthRow "${kind}: ping during the flood: loss (limit $MaxPingLossPct %)" ("{0} of {1} = {2} %" -f $pingLost, $pingSent, $lossPct) '' (($pingSent -gt 0) -and ($lossPct -le $MaxPingLossPct))
    $upDelta = $after.UpMs - $before.UpMs
    Add-EthRow "${kind}: board uptime advanced by about the flood time (no reset)" ("{0} ms in {1} ms" -f $upDelta, $elapsedMs) '' (($before.UpMs -ge 0) -and ($after.UpMs -ge 0) -and ($upBackwards -eq 0) -and ($upDelta -ge ($Seconds * 800)))
    Add-EthRow "${kind}: profile still installed, four classes" $after.Cls.Installed '' ($after.Cls.Installed -and $after.Cls.Classes.Count -eq 4)
    if ($after.Cls.Classes.Count -eq 4 -and $before.Cls.Classes.Count -eq 4) {
        $delta = @{}
        foreach ($name in @('broadcast', 'udp', 'arp', 'icmp')) {
            $b = $before.Cls.Classes[$name]; $a = $after.Cls.Classes[$name]
            $delta[$name] = [pscustomobject]@{ Seen = ($a.Seen - $b.Seen); Passed = ($a.Passed - $b.Passed); Dropped = ($a.Dropped - $b.Dropped); Limit = $a.Limit; Window = $a.Window }
        }
        if ($policed.ContainsKey($kind)) {
            $pc = $policed[$kind]; $d = $delta[$pc]
            Add-EthRow "${kind}: class $pc policed, drops above its limit $($d.Limit) per $($d.Window) ms" ("seen +{0}, passed +{1}, dropped +{2}" -f $d.Seen, $d.Passed, $d.Dropped) '' ($d.Dropped -gt 0)
        } elseif ($reported.ContainsKey($kind)) {
            $rc = $reported[$kind]; $d = $delta[$rc]
            $need = ($kind -eq 'arp') -and $RequireArp
            Add-EthRow "${kind}: class $rc counters (reported, hardware or the PC's stack decides what reaches the CPU)" ("seen +{0}, passed +{1}, dropped +{2}" -f $d.Seen, $d.Passed, $d.Dropped) '' ((-not $need) -or ($d.Seen -gt 0))
        }
        foreach ($name in @('broadcast', 'udp', 'arp', 'icmp')) {
            $isMain = ($policed.ContainsKey($kind) -and $policed[$kind] -eq $name) -or ($reported.ContainsKey($kind) -and $reported[$kind] -eq $name)
            if (-not $isMain) {
                $d = $delta[$name]
                Add-EthRow "${kind}: class $name unaffected (drops within $OtherDropTolerance)" ("seen +{0}, dropped +{1}" -f $d.Seen, $d.Dropped) '' ($d.Dropped -le $OtherDropTolerance)
            }
        }
        if ($kind -eq 'mcast') {
            $seenAll = 0
            foreach ($name in @('broadcast', 'udp', 'arp', 'icmp')) { $seenAll += $delta[$name].Seen }
            Add-EthRow 'mcast: no class counts the multicast frames' $seenAll 'frames' ($seenAll -le $OtherDropTolerance + 50)
            if ($before.Filtered -ge 0 -and $after.Filtered -ge 0 -and $done.Success) {
                $f = $after.Filtered - $before.Filtered
                Add-EthRow 'mcast: ingress filter counted the multicast frames as filtered' ("filtered +{0} for {1} sent" -f $f, $done.Groups[1].Value) '' ($f -gt ([int64]$done.Groups[1].Value / 4))
            }
        }
    }
}
$sp.Close()
Complete-EthTest
