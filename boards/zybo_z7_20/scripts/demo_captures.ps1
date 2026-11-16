<#
-------------------------------------------------------------------------------
File: demo_captures.ps1
Purpose: take the pictures of the Zybo Z7-20 camera demo brief from the running board: decoded camera frames at 720p and 1080p and the
  console captures, so the brief can be built again (for example in daylight) with one command.
Overview:
  * -Port is mandatory (no automatic port selection: the second board of this PC must never be opened; COM5 is refused). The machine-wide board
    lock is taken and released at the end. The firmware must be running (program_demo.ps1 or program.ps1).
  * Per mode (720p30, 1080p15): "camera mode", a UDP capture of the stream for -Seconds, "rx clear" three seconds after the start, "show camera",
    "show stream" and "show rx" near the end of the stream, "stream stop". The decoded picture -FrameSecond seconds into the capture is written with ffmpeg as <Prefix>_frame_<mode>.png.
  * Console captures are rendered from text that this script composes ("rtlnet# <command>" and the board's answer) by
    cpu/microblaze_v_ethernet/test/render_capture.py with --redact: every IPv4 and MAC address becomes a documentation value (192.0.2.x,
    00:00:5E:00:53:xx). Output files in -OutDir (default demos/h264_baseline/images):
      <Prefix>_console.png          show version, show ip, show camera, show rx after the start
      <Prefix>_stream_720p.png      show camera, show stream, show rx during the 720p30 stream
      <Prefix>_stream_1080p.png     the same at 1080p15
      <Prefix>_frame_720p.png       decoded camera frame, 1280 x 720
      <Prefix>_frame_1080p.png      decoded camera frame, 1920 x 1080
  * -Verdicts also runs stream_test.ps1 (-Mode both) and rx_test.ps1 (-Action counters, 60 s per mode) and renders their result lines as
    <Prefix>_stream_test.png and <Prefix>_rx_counters.png (about 10 minutes).
  * The frames show whatever the camera sees: check them for private content before they are committed. Rebuild the PDF afterwards with
    demos\build_brief_pdf.ps1 h264_baseline zybo_z7_20.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/demo_captures.ps1 -Port COM6 [-Verdicts] [-Seconds 14]
    [-FrameSecond 8] [-OutDir <folder>] [-HostIp auto] [-UdpPort 5004] [-Prefix zybo]
Revision: 11-16-2026
  * 11-16-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^COM\d+$')][string]$Port,
    [switch]$Verdicts,
    [int]$Seconds = 14,
    [int]$FrameSecond = 8,
    [string]$OutDir = '',
    [string]$HostIp = 'auto',
    [int]$UdpPort = 5004,
    [string]$Prefix = 'zybo',
    [int]$Baud = 115200
)
$ErrorActionPreference = 'Stop'
if ($Port -eq 'COM5') { Write-Output 'ZYBO_CAPTURES: FAIL COM5 is the other board'; exit 2 }
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
. (Join-Path $Repo 'scripts\rtlnet_board_lock.ps1')
if (-not $OutDir) { $OutDir = Join-Path $Repo 'demos\h264_baseline\images' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$Work = Join-Path $env:TEMP 'rtlnet_zybo_capture'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$ff = Resolve-RtlnetFfmpeg
$py = Resolve-RtlnetPython
$Render = Join-Path $Repo 'cpu\microblaze_v_ethernet\test\render_capture.py'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$PromptRe = '(rtlnet(\([a-z-]+\))?[>#])\s*$'

function Get-Field([string]$text, [string]$re) { if ($text -match $re) { return $Matches[1] } return '' }
function Save-Capture([string]$name, [string]$title, [string]$text) {
    $txt = Join-Path $Work "$name.txt"
    [System.IO.File]::WriteAllText($txt, $text, $utf8)
    $svg = Join-Path $Work "$name.svg"
    & $py -I $Render $txt -o $svg --title $title --redact --max-cols 118 --png | Out-Null
    $png = Join-Path $Work "$name.png"
    if (-not (Test-Path -LiteralPath $png)) { throw "no PNG rendered for $name" }
    Copy-Item -LiteralPath $png -Destination (Join-Path $OutDir "$name.png") -Force
    Write-Output "  wrote $name.png"
}

Enter-RtlnetBoardLock -Purpose 'zybo demo captures' -ExpectedMinutes 40
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.DtrEnable = $false; $sp.RtsEnable = $false
try { $sp.Open() } catch { Write-Output "ZYBO_CAPTURES: FAIL cannot open $Port : $($_.Exception.Message)"; Exit-RtlnetBoardLock; exit 2 }
function Read-UntilPrompt([int]$timeoutMs) {
    $buf = ''; $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $c = $sp.ReadExisting()
        if ($c.Length -gt 0) { $buf += $c; if ($buf.TrimEnd(' ') -match $PromptRe) { Start-Sleep -Milliseconds 50; $buf += $sp.ReadExisting(); return $buf } } else { Start-Sleep -Milliseconds 20 }
    }
    return $buf
}
# One command; the answer without the echo of the command and without the prompt.
function Invoke-Cli([string]$line, [int]$timeoutMs = 8000) {
    $null = $sp.ReadExisting()
    $sp.Write($line + "`r")
    $out = (Read-UntilPrompt $timeoutMs) -replace "`r", ''
    $rows = @($out -split "`n")
    $keep = @()
    foreach ($r in $rows) {
        if ($r.Trim() -eq $line.Trim()) { continue }
        if ($r.Trim() -match '^rtlnet(\([a-z-]+\))?[>#]$') { continue }
        if ($r.Trim() -match "^rtlnet(\([a-z-]+\))?[>#]\s*$([regex]::Escape($line.Trim()))$") { continue }
        if ($r.Trim() -eq '') { continue }
        $keep += $r.TrimEnd()
    }
    return ($keep -join "`n")
}
function Add-Session([System.Text.StringBuilder]$sb, [string]$cmd, [string]$answer) {
    [void]$sb.AppendLine("rtlnet# $cmd")
    if ($answer) { [void]$sb.AppendLine($answer) }
}

$ok = $false
try {
    $ready = $false
    for ($i = 0; $i -lt 60 -and -not $ready; $i++) { $sp.Write("`r"); Start-Sleep -Milliseconds 1500; $t = $sp.ReadExisting(); if ($t -match 'rtlnet[#>]') { $ready = $true } }
    if (-not $ready) { throw 'no console prompt (is the firmware running?)' }
    [void](Invoke-Cli 'enable')
    $ip = Invoke-Cli 'show ip'
    if ($ip -notmatch 'DHCP=1 IP (\d+\.\d+\.\d+\.\d+)') { throw 'no DHCP lease on the board' }
    $boardIp = $Matches[1]
    if ($HostIp -eq 'auto') {
        $pre = ($boardIp -split '\.')[0..2] -join '.'
        $cand = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "$pre.*" })
        if ($cand.Count -lt 1) { throw 'this PC has no address on the board subnet (give -HostIp)' }
        $HostIp = $cand[0].IPAddress
    }
    [void](Invoke-Cli 'stream stop')

    # ---- console after the start ----
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in 'show version', 'show ip', 'show camera', 'show rx') { Add-Session $sb $c (Invoke-Cli $c) }
    Save-Capture "${Prefix}_console" 'Zybo Z7-20 console: show version, show ip, show camera, show rx' $sb.ToString()

    # ---- UDP capture thread ----
    if (-not ('ZyboUdpCapture' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.IO; using System.Net; using System.Net.Sockets; using System.Threading; using System.Diagnostics;
public class ZyboUdpCapture {
    Socket sock; Thread th; FileStream fs; byte[] buf = new byte[65536];
    public long Datagrams, Bytes; public double FirstAt = -1, LastAt; double seconds; Stopwatch sw = new Stopwatch();
    public void Start(int port, string file, double secs) {
        seconds = secs; sock = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        sock.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        sock.ReceiveBufferSize = 16 * 1024 * 1024; sock.Bind(new IPEndPoint(IPAddress.Any, port));
        fs = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.Read, 1024 * 1024); sw.Start();
        th = new Thread(Run); th.IsBackground = true; th.Start();
    }
    void Run() {
        while (true) {
            double now = sw.Elapsed.TotalSeconds;
            if (FirstAt < 0) { if (now > seconds + 30) break; } else if (now - FirstAt >= seconds) break;
            if (sock.Poll(200000, SelectMode.SelectRead)) {
                int n = sock.Receive(buf, 0, buf.Length, SocketFlags.None); double t = sw.Elapsed.TotalSeconds;
                if (FirstAt < 0) FirstAt = t; LastAt = t; fs.Write(buf, 0, n); Datagrams++; Bytes += n;
            }
        }
        fs.Flush(); fs.Close(); sock.Close();
    }
    public bool Join(int ms) { return th.Join(ms); }
}
'@
    }

    foreach ($m in @(@('720p', '720p30', 30), @('1080p', '1080p15', 15))) {
        $mode = $m[0]; $cli = $m[1]; $fps = $m[2]
        $ts = Join-Path $Work "${Prefix}_$mode.ts"
        $sb = New-Object System.Text.StringBuilder
        Write-Output "== $mode"
        Add-Session $sb "camera mode $cli" (Invoke-Cli "camera mode $cli" 15000)
        Start-Sleep -Milliseconds 1500
        $cap = New-Object ZyboUdpCapture
        $cap.Start($UdpPort, $ts, $Seconds)
        Add-Session $sb "stream start $HostIp $UdpPort" (Invoke-Cli "stream start $HostIp $UdpPort" 15000)
        Start-Sleep -Seconds 3
        Add-Session $sb 'rx clear' (Invoke-Cli 'rx clear')
        Start-Sleep -Seconds ([Math]::Max(3, $Seconds - 8))
        Add-Session $sb 'show camera' (Invoke-Cli 'show camera')
        Add-Session $sb 'show stream' (Invoke-Cli 'show stream')
        Add-Session $sb 'show rx' (Invoke-Cli 'show rx')
        [void]$cap.Join(($Seconds + 40) * 1000)
        Add-Session $sb 'stream stop' (Invoke-Cli 'stream stop' 15000)
        Write-Output ("  capture: {0} datagrams, {1} bytes" -f $cap.Datagrams, $cap.Bytes)
        if ($cap.Datagrams -eq 0) { throw ("no datagram received: the Windows firewall probably blocks UDP port $UdpPort") }
        Save-Capture "${Prefix}_stream_$mode" "Zybo Z7-20 console: $cli stream" $sb.ToString()
        $png = Join-Path $Work "${Prefix}_frame_$mode.png"
        if (Test-Path -LiteralPath $png) { Remove-Item -LiteralPath $png }
        $n = [int]($fps * $FrameSecond)
        & $ff.Ffmpeg -v error -y -i $ts -vf "select=eq(n\,$n)" -frames:v 1 $png 2>$null
        if (-not (Test-Path -LiteralPath $png)) { throw "ffmpeg wrote no frame for $mode" }
        Copy-Item -LiteralPath $png -Destination (Join-Path $OutDir "${Prefix}_frame_$mode.png") -Force
        Write-Output "  wrote ${Prefix}_frame_$mode.png"
    }
    $ok = $true
} catch {
    Write-Output "ZYBO_CAPTURES: FAIL $($_.Exception.Message)"
} finally {
    try { [void](Invoke-Cli 'stream stop') } catch { }
    $sp.Close()
}

# ---- the verdict captures (the host tests open the port themselves) ----
if ($ok -and $Verdicts) {
    function Save-Verdict([string]$name, [string]$title, [string[]]$lines) {
        $keep = @($lines | Where-Object { $_ -match '^==|^\s+(ok|FAIL)\s|ZYBO_|^board:|^firmware:' } | ForEach-Object {
            $l = ($_ -replace '\s+$', ''); if ($l.Length -gt 116) { $l.Substring(0, 113) + '...' } else { $l } })
        Save-Capture $name $title (($keep -join "`n") + "`n")
    }
    Write-Output '== stream_test.ps1 -Mode both'
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'stream_test.ps1') -Mode both -Port $Port -HostIp $HostIp -UdpPort $UdpPort -Tag "${Prefix}_cap" 2>&1 | ForEach-Object { "$_" }
    $o | Where-Object { $_ -match 'ZYBO_STREAM_TEST' } | ForEach-Object { Write-Output $_ }
    Save-Verdict "${Prefix}_stream_test" 'stream_test.ps1 -Mode both -Port COM6' $o
    Write-Output '== rx_test.ps1 -Action counters'
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'rx_test.ps1') -Port $Port -Action counters -Mode both -Seconds 60 -HostIp $HostIp -UdpPort $UdpPort -Tag "${Prefix}_cap" 2>&1 | ForEach-Object { "$_" }
    $o | Where-Object { $_ -match 'ZYBO_RX' } | ForEach-Object { Write-Output $_ }
    Save-Verdict "${Prefix}_rx_counters" 'rx_test.ps1 -Action counters -Port COM6' $o
}
Exit-RtlnetBoardLock
Write-Output ("ZYBO_CAPTURES: {0}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }))
exit $(if ($ok) { 0 } else { 1 })
