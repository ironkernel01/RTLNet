<#
-------------------------------------------------------------------------------
File: rx_test.ps1
Purpose: measure the own camera receiver (rtlnet_csi2_rx) of the Zybo Z7-20 own-receiver image on the board: receiver counters over a
  streaming interval, and the D-PHY capture margin (IDELAY tap sweep) with the errors counted at every tap.
Overview:
  * -Port is mandatory (no automatic port selection: the second board of this PC must never be opened). The machine-wide board lock is taken
    (rtlnet_board_lock.ps1) and released at the end of the run. The firmware (own-receiver image) must be running.
  * -Action counters: per mode (720p, 1080p, or both) "camera mode", "rx clear", "stream start <PC address> <port>", -Seconds of streaming,
    "show rx" at the start and the end. One line per criterion: frames counted at the sensor rate (30 fps), ECC uncorrectable, CRC, SOT,
    size mismatches all 0 (ECC corrected, FIFO overflow, orphan lines, word count, truncation, data type and clock loss are reported and judged
    0 as well, except ECC corrected which is reported only). Last line "ZYBO_RX_COUNTERS: PASS|FAIL".
  * -Action sweep: per mode the stream runs; for every tap value of -TapFrom..-TapTo "rx taps" is written, the counters are cleared, the receiver
    runs -Dwell seconds and "show rx" is read. -Lane both (both lanes the same tap), 0 or 1 (one lane swept, the other held at -OtherTap).
    Output: a table per mode and the error-free window (taps with ECC uncorrectable, CRC, SOT, size, orphan, length, truncation and overflow all 0, frame rate within
    1 fps of the sensor), plus rx_sweep_<tag>.csv in boards/zybo_z7_20/build. The default taps are restored at the end.
  * The UDP stream is received (and discarded into a file) so that the encoder runs as in the product; a Windows firewall that blocks UDP shows
    as no datagram received.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/rx_test.ps1 -Port COM6 -Action counters [-Mode both] [-Seconds 60]
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/rx_test.ps1 -Port COM6 -Action sweep [-Mode both] [-Dwell 3] [-Lane both] [-OtherTap 12]
Revision: 11-15-2026. Initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^COM\d+$')][string]$Port,
    [ValidateSet('counters', 'sweep')][string]$Action = 'counters',
    [ValidateSet('720p', '1080p', 'both')][string]$Mode = 'both',
    [int]$Seconds = 60,
    [int]$Dwell = 3,
    [ValidateSet('both', '0', '1')][string]$Lane = 'both',
    [int]$TapFrom = 0,
    [int]$TapTo = 31,
    [int]$OtherTap = 12,
    [int]$DefaultTap0 = 12,
    [int]$DefaultTap1 = 12,
    [string]$Tag = 'rx',
    [int]$Baud = 115200,
    [int]$UdpPort = 5004,
    [string]$HostIp = 'auto'
)
$ErrorActionPreference = 'Stop'
if ($Port -eq 'COM5') { Write-Output 'ZYBO_RX: FAIL COM5 is the other board'; exit 2 }
$Repo  = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Build = Join-Path $Board 'build'
New-Item -ItemType Directory -Force -Path $Build | Out-Null
. (Join-Path $Repo 'scripts\rtlnet_board_lock.ps1')
$PromptRe = '(rtlnet(\([a-z-]+\))?[>#])\s*$'
$script:results = @()
function Add-Result([string]$name, [bool]$ok, [string]$detail) {
    $script:results += [pscustomobject]@{ Step = $name; Ok = $ok; Detail = $detail }
    Write-Output ("  {0,-4} {1,-30} {2}" -f ($(if ($ok) { 'ok' } else { 'FAIL' })), $name, $detail)
}
Enter-RtlnetBoardLock -Purpose 'zybo rx test' -ExpectedMinutes 45
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.DtrEnable = $false; $sp.RtsEnable = $false
try { $sp.Open() } catch { Write-Output "ZYBO_RX: FAIL cannot open $Port : $($_.Exception.Message)"; Exit-RtlnetBoardLock; exit 2 }
function Read-UntilPrompt([int]$timeoutMs) {
    $buf = ''; $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $c = $sp.ReadExisting()
        if ($c.Length -gt 0) { $buf += $c; if ($buf.TrimEnd(' ') -match $PromptRe) { Start-Sleep -Milliseconds 50; $buf += $sp.ReadExisting(); return $buf } } else { Start-Sleep -Milliseconds 20 }
    }
    return $buf
}
function Invoke-Cli([string]$line, [int]$timeoutMs = 8000) {
    $sp.Write($line + "`r")
    return ((Read-UntilPrompt $timeoutMs) -replace "`r", '')
}
$names = 'ECC_CORR', 'ECC_UNC', 'CRC', 'SOT', 'FRAMES', 'DT', 'TRUNC', 'OVF', 'SIZE', 'ORPHAN', 'LEN', 'CLKLOSS'
function Get-Rx {
    $t = Invoke-Cli 'show rx'
    $h = @{}
    foreach ($n in $names) { if ($t -match "\b$n=(\d+)") { $h[$n] = [int64]$Matches[1] } else { $h[$n] = -1 } }
    if ($t -match 'status=0x([0-9a-f]+)') { $h['status'] = [Convert]::ToInt32($Matches[1], 16) } else { $h['status'] = -1 }
    if ($t -match 'taps=(\d+),(\d+)') { $h['tap0'] = [int]$Matches[1]; $h['tap1'] = [int]$Matches[2] }
    if ($t -match 'lines=(\d+) pixels=(\d+)') { $h['lines'] = [int]$Matches[1]; $h['pixels'] = [int]$Matches[2] }
    if ($t -match 'clkrun=(\d+) dlyrdy=(\d+)') { $h['clkrun'] = [int]$Matches[1]; $h['dlyrdy'] = [int]$Matches[2] }
    $h['raw'] = $t
    return $h
}
function Get-Seen { $t = Invoke-Cli 'show camera'; if ($t -match 'seen=(\d+) admitted=(\d+)') { return @([int64]$Matches[1], [int64]$Matches[2]) } return @(-1, -1) }

$ready = $false
for ($i = 0; $i -lt 60 -and -not $ready; $i++) { $sp.Write("`r"); Start-Sleep -Milliseconds 1500; if ($sp.ReadExisting() -match 'rtlnet[#>]') { $ready = $true } }
if (-not $ready) { Write-Output 'ZYBO_RX: FAIL no console prompt'; $sp.Close(); Exit-RtlnetBoardLock; exit 2 }
[void](Invoke-Cli 'enable')
$cam = Invoke-Cli 'show camera'
if ($cam -notmatch 'receiver=own') { Write-Output 'ZYBO_RX: FAIL the running image has no own receiver'; $sp.Close(); Exit-RtlnetBoardLock; exit 2 }
$ip = Invoke-Cli 'show ip'
if ($ip -notmatch 'DHCP=1 IP (\d+\.\d+\.\d+\.\d+)') { Write-Output 'ZYBO_RX: FAIL no DHCP lease'; $sp.Close(); Exit-RtlnetBoardLock; exit 2 }
$boardIp = $Matches[1]
if ($HostIp -eq 'auto') {
    $pre = ($boardIp -split '\.')[0..2] -join '.'
    $cand = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "$pre.*" })
    if ($cand.Count -lt 1) { Write-Output 'ZYBO_RX: FAIL no PC address on the board subnet'; $sp.Close(); Exit-RtlnetBoardLock; exit 2 }
    $HostIp = $cand[0].IPAddress
}
if (-not ('ZyboRxUdp' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.IO; using System.Net; using System.Net.Sockets; using System.Threading; using System.Diagnostics;
public class ZyboRxUdp {
    Socket sock; Thread th; byte[] buf = new byte[65536]; volatile bool stop;
    public long Datagrams, Bytes;
    public void Start(int port) {
        sock = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        sock.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        sock.ReceiveBufferSize = 16 * 1024 * 1024; sock.Bind(new IPEndPoint(IPAddress.Any, port));
        th = new Thread(Run); th.IsBackground = true; th.Start();
    }
    void Run() { while (!stop) { if (sock.Poll(200000, SelectMode.SelectRead)) { int n = sock.Receive(buf, 0, buf.Length, SocketFlags.None); Datagrams++; Bytes += n; } } sock.Close(); }
    public void Stop() { stop = true; th.Join(2000); }
}
'@
}
function Start-Mode([string]$m) {
    [void](Invoke-Cli 'stream stop')
    $r = Invoke-Cli "camera mode $($m)$(if ($m -eq '720p') { '30' } else { '15' })" 15000
    if ($r -match '%|nvalid|rror') { throw "camera mode $m : $r" }
    Start-Sleep -Milliseconds 1500
    $r = Invoke-Cli "stream start $HostIp $UdpPort" 15000
    if ($r -match '%|nvalid|rror') { throw "stream start: $r" }
}
function Format-Row($h) { ($names | ForEach-Object { "$_=$($h[$_])" }) -join ' ' }

$udp = New-Object ZyboRxUdp
$udp.Start($UdpPort)
$modes = @(); if ($Mode -in '720p', 'both') { $modes += '720p' }; if ($Mode -in '1080p', 'both') { $modes += '1080p' }
$csv = New-Object System.Text.StringBuilder
try {
    foreach ($m in $modes) {
        Write-Output "== mode $m"
        Start-Mode $m
        Start-Sleep -Seconds 4
        if ($Action -eq 'counters') {
            [void](Invoke-Cli 'rx clear')
            $a = Get-Rx; $s0 = Get-Seen; $t0 = Get-Date
            Start-Sleep -Seconds $Seconds
            $b = Get-Rx; $s1 = Get-Seen; $t1 = Get-Date
            $secs = ($t1 - $t0).TotalSeconds
            Write-Output ("  start: " + (Format-Row $a))
            Write-Output ("  end  : " + (Format-Row $b) + " status=0x{0:x3} lines={1} pixels={2}" -f $b['status'], $b['lines'], $b['pixels'])
            $fps = ($b['FRAMES'] - $a['FRAMES']) / $secs
            $sensorFps = ($s1[0] - $s0[0]) / $secs
            $admFps = ($s1[1] - $s0[1]) / $secs
            Add-Result "$m frames" ([Math]::Abs($fps - 30.0) -lt 1.0 -and [Math]::Abs($sensorFps - 30.0) -lt 1.0) ("receiver {0:N2} fps over {1:N1} s (counter {2} to {3}); camera block seen {4:N2} fps, admitted {5:N2} fps" -f $fps, $secs, $a['FRAMES'], $b['FRAMES'], $sensorFps, $admFps)
            foreach ($n in 'ECC_UNC', 'CRC', 'SOT', 'SIZE', 'OVF', 'ORPHAN', 'LEN', 'TRUNC', 'DT', 'CLKLOSS') {
                $d = $b[$n] - $a[$n]
                Add-Result "$m $n" ($d -eq 0) "delta $d (end value $($b[$n]))"
            }
            Write-Output ("  info ECC_CORR delta {0} (corrected single-bit header errors, not an error of the picture)" -f ($b['ECC_CORR'] - $a['ECC_CORR']))
        } else {
            Write-Output "  sweep lane=$Lane dwell=$Dwell s, taps $TapFrom..$TapTo (78 ps per tap at 200 MHz)"
            $rows = @()
            for ($tap = $TapFrom; $tap -le $TapTo; $tap++) {
                $t0v = $tap; $t1v = $tap
                if ($Lane -eq '0') { $t1v = $OtherTap } elseif ($Lane -eq '1') { $t0v = $OtherTap }
                [void](Invoke-Cli "rx taps $t0v $t1v")
                Start-Sleep -Milliseconds 1200
                [void](Invoke-Cli 'rx clear')
                $s0 = Get-Seen; $t0 = Get-Date
                Start-Sleep -Seconds $Dwell
                $h = Get-Rx; $s1 = Get-Seen; $secs = ((Get-Date) - $t0).TotalSeconds
                $fps = ($h['FRAMES']) / $secs
                $h['tap'] = $tap; $h['fps'] = $fps; $h['seen'] = ($s1[0] - $s0[0]) / $secs
                $bad = $h['ECC_UNC'] + $h['CRC'] + $h['SOT'] + $h['SIZE'] + $h['ORPHAN'] + $h['LEN'] + $h['TRUNC'] + $h['OVF'] + $h['DT']
                $h['clean'] = ($bad -eq 0 -and [Math]::Abs($fps - 30.0) -lt 1.0 -and $h['CLKLOSS'] -eq 0)
                $rows += $h
                Write-Output ("  tap {0,2} ({1,4} ps) {2} frames/s={3:N1} {4}" -f $tap, [int]($tap * 78), (Format-Row $h), $fps, $(if ($h['clean']) { 'clean' } else { 'ERRORS' }))
                $cnt = ($names | ForEach-Object { $h[$_] }) -join ';'
                $cl = if ($h['clean']) { 1 } else { 0 }
                [void]$csv.AppendLine(("{0},{1},{2},{3},{4},{5:N2},{6}" -f $m, $Lane, $tap, $cl, $cnt, $fps, $h['status']))
            }
            $clean = @($rows | Where-Object { $_['clean'] } | ForEach-Object { $_['tap'] })
            if ($clean.Count -eq 0) { Write-Output "  RESULT $m lane=$Lane : no error-free tap in $TapFrom..$TapTo" }
            else {
                # longest run of consecutive clean taps
                $best = @(); $cur = @()
                foreach ($tp in $clean) { if ($cur.Count -and $tp -eq $cur[-1] + 1) { $cur += $tp } else { $cur = @($tp) }; if ($cur.Count -gt $best.Count) { $best = @($cur) } }
                $lo = $best[0]; $hi = $best[-1]
                Write-Output ("  RESULT {0} lane={1}: error-free taps {2}..{3} = {4} taps = {5} ps wide, centre tap {6} ({7} ps); clean taps in total {8} of {9}" -f $m, $Lane, $lo, $hi, ($hi - $lo + 1), (($hi - $lo + 1) * 78), [Math]::Round(($lo + $hi) / 2.0, 1), [int](($lo + $hi) / 2.0 * 78), $clean.Count, $rows.Count)
            }
            [void](Invoke-Cli "rx taps $DefaultTap0 $DefaultTap1")
        }
    }
} finally {
    try { [void](Invoke-Cli 'stream stop'); [void](Invoke-Cli "rx taps $DefaultTap0 $DefaultTap1") } catch { }
    $udp.Stop()
    $sp.Close()
    if ($csv.Length) { [System.IO.File]::WriteAllText((Join-Path $Build "rx_sweep_$Tag.csv"), "mode,lane,tap,clean,counters(ECC_CORR;ECC_UNC;CRC;SOT;FRAMES;DT;TRUNC;OVF;SIZE;ORPHAN;LEN;CLKLOSS),fps,status`r`n" + $csv.ToString(), (New-Object System.Text.UTF8Encoding($false))) }
    Exit-RtlnetBoardLock
}
Write-Output ("udp datagrams received by the PC: {0}" -f $udp.Datagrams)
if ($Action -eq 'counters') {
    $bad = @($script:results | Where-Object { -not $_.Ok }).Count
    Write-Output ("ZYBO_RX_COUNTERS: {0} {1}/{2}" -f $(if ($bad -eq 0) { 'PASS' } else { 'FAIL' }), $(if ($bad -eq 0) { $script:results.Count } else { $bad }), $script:results.Count)
    exit $(if ($bad -eq 0) { 0 } else { 1 })
}
