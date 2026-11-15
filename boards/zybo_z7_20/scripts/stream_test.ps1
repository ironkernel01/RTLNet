<#
-------------------------------------------------------------------------------
File: stream_test.ps1
Purpose: board gate of the Zybo Z7-20 camera design: the real camera is encoded by the Baseline engine and streamed as MPEG-TS over UDP;
  this PC receives the datagrams, checks the stream with the shared parser, ffprobe and ffmpeg, measures the sensor and stream frame rates
  from the board counters and saves decoded pictures.
Overview:
  * Takes the machine-wide board lock (rtlnet_board_lock.ps1). The console is the board USB-UART (115200 8N1); with -Port auto the one USB
    serial port is used (enumeration, no fixed name). Tools through scripts/rtlnet_tools.ps1 (Resolve-RtlnetFfmpeg, Resolve-RtlnetPython).
    The TS parser is the one of the Nexys Video test (boards/nexys_video/scripts/stream_check.py ts / reorder / trim), called with the
    PTS step and the frame rate of the mode (720p: 3000 and 30 fps, 1080p: 6000 and 15 fps) instead of a copy.
  * The firmware must be running (program.ps1). Per mode (720p, 1080p, or both): "camera mode", "stream start <PC address> <port>", a
    capture of the datagrams as received for -Seconds, "show camera" twice during the capture (sensor and admitted frame rate), "show
    stream", "stream stop". Results, one line each:
      ts       stream_check.py ts: 188-byte packets, continuity counters, PAT and PMT CRC-32, PCR, PES, PTS steps, IDR every -Gop pictures
      probe    ffprobe: one h264 Constrained Baseline stream, the width and height of the mode, the frame rate of the mode
      decode   ffmpeg decodes the whole capture without an error message
      picture  the decoded picture four seconds into the capture (the sensor exposure has settled) is written as PNG (build/<Tag>_<mode>_frame.png) and its luma range is checked (not black, not flat)
      sensor   the sensor frame rate from the frame counter of "show camera" (30 fps in both modes, +-1)
      stream   the admitted frame rate (720p: 30 fps, 1080p: 15 fps, +-1)
      board    show stream: no encoder errors, no dropped pictures, no UDP drops
    The last line is "ZYBO_STREAM_TEST: PASS <n>/<n>" or "ZYBO_STREAM_TEST: FAIL <failed>/<n>"; exit code 0 only on PASS.
  * -HostIp auto picks the PC address on the subnet of the board lease; give it explicitly when the PC has several adapters on that subnet.
    A Windows firewall that blocks UDP shows as datagrams sent by the board and none received (the script prints this; it never changes the
    firewall).
  * Output files: boards/zybo_z7_20/build/<Tag>_<mode>.ts, _ts.txt, _probe.json, _decode.txt, _frame.png, and the transcript <Tag>_transcript.txt.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/stream_test.ps1 [-Mode both] [-Seconds 20] [-Port auto]
    [-HostIp auto] [-UdpPort 5004] [-Gop 30] [-Tag zybo_stream] [-InputTs <file> -Width 1280 -Height 720 -Fps 30 -Steps 3000]
Revision: 11-15-2026
  * 11-15-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [ValidateSet('720p', '1080p', 'both')][string]$Mode = 'both',
    [int]$Seconds = 20,
    [string]$Port = 'auto',
    [int]$Baud = 115200,
    [int]$UdpPort = 5004,
    [string]$HostIp = 'auto',
    [ValidateRange(1, 255)][int]$Gop = 30,
    [string]$Tag = 'zybo_stream',
    [string]$InputTs = '',
    [int]$Width = 1280,
    [int]$Height = 720,
    [int]$Fps = 30,
    [int]$Steps = 3000,
    [int]$StepTimeoutMs = 8000
)
$ErrorActionPreference = 'Stop'
$Repo  = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Build = Join-Path $Board 'build'
New-Item -ItemType Directory -Force -Path $Build | Out-Null
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
$ff = Resolve-RtlnetFfmpeg
$py = Resolve-RtlnetPython
$Check = Join-Path $Repo 'boards\nexys_video\scripts\stream_check.py'
$script:log = New-Object System.Text.StringBuilder
$script:results = @()
$PromptRe = '(rtlnet(\([a-z-]+\))?[>#])\s*$'
function Say([string]$s) { Write-Output $s; [void]$script:log.AppendLine($s) }
function Add-Result([string]$name, [bool]$ok, [string]$detail) {
    $script:results += [pscustomobject]@{ Step = $name; Ok = $ok; Detail = $detail }
    Say ("  {0,-4} {1,-36} {2}" -f ($(if ($ok) { 'ok' } else { 'FAIL' })), $name, $detail)
}
function Invoke-Native([string]$exe, [string[]]$arguments, [string]$outFile) {
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError ($outFile + '.err')
    return $p.ExitCode
}
function Get-Field([string]$text, [string]$re) { if ($text -match $re) { return $Matches[1] } return '0' }

# ---- the checks on one capture (also the offline entry with -InputTs) ----
function Test-Capture([string]$name, [string]$ts, [int]$w, [int]$h, [double]$fps, [int]$step) {
    $o = Join-Path $Build "${name}_ts.txt"
    [void](Invoke-Native $py @('-I', $Check, 'trim', $ts) (Join-Path $Build "${name}_trim.txt"))
    $rc = Invoke-Native $py @('-I', $Check, 'ts', $ts, '--steps', "$step", '--fps', "$fps", '--gop', "$Gop") $o
    $lines = @(Get-Content -LiteralPath $o)
    foreach ($l in $lines) { [void]$script:log.AppendLine($l) }
    $fail = @($lines | Where-Object { $_ -match '^CHECK \S+ FAIL' })
    $sum = ($lines | Where-Object { $_ -match '^TS_SUMMARY' } | Select-Object -Last 1)
    Add-Result "$name ts" ($rc -eq 0 -and $fail.Count -eq 0) ("$sum" + $(if ($fail.Count) { ' | ' + (($fail | ForEach-Object { $_.Substring(6, [Math]::Min(90, $_.Length - 6)) }) -join ' | ') } else { '' }))
    $pj = Join-Path $Build "${name}_probe.json"
    $rc = Invoke-Native $ff.Ffprobe @('-v', 'error', '-show_streams', '-of', 'json', $ts) $pj
    $probe = $null
    try { $probe = (Get-Content -LiteralPath $pj -Raw) | ConvertFrom-Json } catch { }
    $vs = @(); if ($probe) { $vs = @($probe.streams) }
    $rate = 0.0
    if ($vs.Count -ge 1 -and $vs[0].avg_frame_rate -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -gt 0) { $rate = [int]$Matches[1] / [int]$Matches[2] }
    $okp = ($rc -eq 0 -and $vs.Count -eq 1 -and $vs[0].codec_name -eq 'h264' -and $vs[0].profile -eq 'Constrained Baseline' -and [int]$vs[0].width -eq $w -and [int]$vs[0].height -eq $h -and [Math]::Abs($rate - $fps) -lt 1.0)
    Add-Result "$name probe" $okp ("{0} stream(s), {1} {2} {3}x{4}, {5:N2} fps" -f $vs.Count, $(if ($vs.Count) { $vs[0].codec_name } else { '-' }), $(if ($vs.Count) { $vs[0].profile } else { '-' }), $(if ($vs.Count) { $vs[0].width } else { 0 }), $(if ($vs.Count) { $vs[0].height } else { 0 }), $rate)
    $df = Join-Path $Build "${name}_decode.txt"
    $png = Join-Path $Build "${name}_frame.png"
    $rc = Invoke-Native $ff.Ffmpeg @('-v', 'error', '-y', '-i', $ts, '-vf', "select=eq(n\,$([int]($fps * 4)))", '-frames:v', '1', $png) $df
    $errLines = @(Get-Content -LiteralPath ($df + '.err') -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    # the whole capture, errors only
    $rc2 = Invoke-Native $ff.Ffmpeg @('-v', 'error', '-i', $ts, '-f', 'null', '-') (Join-Path $Build "${name}_decode_all.txt")
    $errAll = @(Get-Content -LiteralPath ((Join-Path $Build "${name}_decode_all.txt") + '.err') -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    Add-Result "$name decode" ($rc -eq 0 -and $rc2 -eq 0 -and $errAll.Count -eq 0) ("exit $rc2, $($errAll.Count) error line(s)" + $(if ($errAll.Count) { ': ' + $errAll[0] } else { '' }))
    $sd = Join-Path $Build "${name}_stats.txt"
    $range = 0
    if (Test-Path -LiteralPath $png) {
        [void](Invoke-Native $ff.Ffmpeg @('-v', 'info', '-i', $png, '-vf', 'signalstats,metadata=print:file=-', '-f', 'null', '-') $sd)
        $st = (Get-Content -LiteralPath $sd -Raw) + (Get-Content -LiteralPath ($sd + '.err') -Raw -ErrorAction SilentlyContinue)
        $lo = [double](Get-Field $st 'lavfi.signalstats.YLOW=([0-9.]+)'); $hi = [double](Get-Field $st 'lavfi.signalstats.YHIGH=([0-9.]+)')
        $range = $hi - $lo
    }
    Add-Result "$name picture" ((Test-Path -LiteralPath $png) -and $range -ge 40) ("$png, luma range (1st to 99th percentile) $range")
}

if ($InputTs) {
    $nm = [System.IO.Path]::GetFileNameWithoutExtension($InputTs)
    Test-Capture $nm $InputTs $Width $Height $Fps $Steps
    $bad = @($script:results | Where-Object { -not $_.Ok }).Count
    Write-Output ("ZYBO_STREAM_TEST: {0} {1}/{2}" -f $(if ($bad -eq 0) { 'PASS' } else { 'FAIL' }), $(if ($bad -eq 0) { $script:results.Count } else { $bad }), $script:results.Count)
    exit $(if ($bad -eq 0) { 0 } else { 1 })
}

. (Join-Path $Repo 'scripts\rtlnet_board_lock.ps1')
Enter-RtlnetBoardLock -Purpose 'zybo stream test' -ExpectedMinutes 30

# ---- serial console ----
if ($Port -eq 'auto') {
    $names = @([System.IO.Ports.SerialPort]::GetPortNames())
    if ($names.Count -ne 1) { Write-Output "ZYBO_STREAM_TEST: FAIL serial ports found: $($names -join ',') (give -Port)"; exit 2 }
    $Port = $names[0]
}
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.DtrEnable = $false; $sp.RtsEnable = $false
try { $sp.Open() } catch { Write-Output "ZYBO_STREAM_TEST: FAIL cannot open $Port : $($_.Exception.Message)"; exit 2 }
function Read-UntilPrompt([int]$timeoutMs) {
    $buf = ''; $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $c = $sp.ReadExisting()
        if ($c.Length -gt 0) { $buf += $c; if ($buf.TrimEnd(' ') -match $PromptRe) { Start-Sleep -Milliseconds 50; $buf += $sp.ReadExisting(); return $buf } } else { Start-Sleep -Milliseconds 20 }
    }
    return $buf
}
function Invoke-Cli([string]$line, [int]$timeoutMs = 0) {
    if ($timeoutMs -le 0) { $timeoutMs = $StepTimeoutMs }
    $sp.Write($line + "`r")
    $out = Read-UntilPrompt $timeoutMs
    [void]$script:log.Append($out)
    return ($out -replace "`r", '')
}
# wait for the firmware to reach its prompt (it takes about 40 s after the load: sensor start-up and DHCP)
$ready = $false
for ($i = 0; $i -lt 60 -and -not $ready; $i++) { $sp.Write("`r"); Start-Sleep -Milliseconds 1500; $t = $sp.ReadExisting(); if ($t -match 'rtlnet[#>]') { $ready = $true } }
if (-not $ready) { Write-Output 'ZYBO_STREAM_TEST: FAIL no console prompt (is the firmware running?)'; $sp.Close(); exit 2 }
[void](Invoke-Cli 'enable')
$ip = Invoke-Cli 'show ip'
Say ($ip -split "`n" | Where-Object { $_ -match 'PHY' } | ForEach-Object { 'board: ' + ($_ -replace 'IP \S+', 'IP <lease>') })
if ($ip -notmatch 'DHCP=1 IP (\d+\.\d+\.\d+\.\d+)') { Write-Output 'ZYBO_STREAM_TEST: FAIL no DHCP lease on the board'; $sp.Close(); exit 2 }
$boardIp = $Matches[1]
if ($HostIp -eq 'auto') {
    $pre = ($boardIp -split '\.')[0..2] -join '.'
    $cand = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "$pre.*" })
    if ($cand.Count -lt 1) { Write-Output 'ZYBO_STREAM_TEST: FAIL this PC has no address on the board subnet (give -HostIp)'; $sp.Close(); exit 2 }
    $HostIp = $cand[0].IPAddress
}
$ver = Invoke-Cli 'show version'
Say ('firmware: ' + (($ver -split "`n" | Where-Object { $_ -match 'RTLNet Zybo' } | Select-Object -First 1)))

# ---- UDP capture (a thread, so the socket never overflows while the console is read) ----
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

function Test-Mode([string]$m, [int]$w, [int]$h, [double]$fps, [int]$step, [double]$streamFps) {
    $name = "${Tag}_$m"
    $ts = Join-Path $Build "$name.ts"
    Say "== mode $m"
    [void](Invoke-Cli 'stream stop')
    $r = Invoke-Cli "camera mode $($m)$(if ($m -eq '720p') { '30' } else { '15' })" 15000
    if ($r -match '%|nvalid|rror') { Add-Result "$name mode" $false $r.Trim(); return }
    Start-Sleep -Milliseconds 1500
    $cap = New-Object ZyboUdpCapture
    $cap.Start($UdpPort, $ts, $Seconds)
    $r = Invoke-Cli "stream start $HostIp $UdpPort" 15000
    if ($r -match '%|nvalid|rror') { Add-Result "$name start" $false $r.Trim(); $cap.Join(1000) | Out-Null; return }
    Start-Sleep -Seconds 3
    $c1 = Invoke-Cli 'show camera'; $t1 = Get-Date
    Start-Sleep -Seconds ([Math]::Max(5, $Seconds - 8))
    $c2 = Invoke-Cli 'show camera'; $t2 = Get-Date
    [void]$cap.Join(($Seconds + 40) * 1000)
    $ss = Invoke-Cli 'show stream'
    [void](Invoke-Cli 'stream stop')
    Say ("capture: {0} datagrams, {1} bytes" -f $cap.Datagrams, $cap.Bytes)
    $secs = ($t2 - $t1).TotalSeconds
    $s1 = [double](Get-Field $c1 'seen=(\d+)'); $s2 = [double](Get-Field $c2 'seen=(\d+)')
    $a1 = [double](Get-Field $c1 'admitted=(\d+)'); $a2 = [double](Get-Field $c2 'admitted=(\d+)')
    $sensor = ($s2 - $s1) / $secs; $adm = ($a2 - $a1) / $secs
    Add-Result "$name sensor" ([Math]::Abs($sensor - 30.0) -lt 1.0) ("{0:N2} fps over {1:N1} s (frames seen {2} to {3})" -f $sensor, $secs, $s1, $s2)
    Add-Result "$name stream rate" ([Math]::Abs($adm - $streamFps) -lt 1.0) ("{0:N2} fps admitted (expected {1})" -f $adm, $streamFps)
    $err = [int](Get-Field $ss 'errors=(\d+)'); $drops = [int](Get-Field $ss 'drops=(\d+)'); $sent = [int](Get-Field $ss 'datagrams=(\d+)')
    Add-Result "$name board" ($err -eq 0 -and $drops -eq 0) ("show stream: errors=$err dropped pictures=$drops datagrams sent=$sent received=$($cap.Datagrams)")
    if ($cap.Datagrams -eq 0 -and $sent -gt 0) {
        Say "  The board sent datagrams and this PC received none: the Windows firewall probably blocks UDP port $UdpPort. Allow it from an elevated prompt (the script never changes the firewall)."
        Add-Result "$name receive" $false 'no datagram received'
        return
    }
    Test-Capture $name $ts $w $h $fps $step
}

try {
    if ($Mode -in '720p', 'both') { Test-Mode '720p' 1280 720 30 3000 30.0 }
    if ($Mode -in 'both', '1080p') { Test-Mode '1080p' 1920 1080 15 6000 15.0 }
} finally {
    try { [void](Invoke-Cli 'stream stop') } catch { }
    $sp.Close()
    [System.IO.File]::WriteAllText((Join-Path $Build "${Tag}_transcript.txt"), $script:log.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}
$bad = @($script:results | Where-Object { -not $_.Ok }).Count
Write-Output ("ZYBO_STREAM_TEST: {0} {1}/{2}" -f $(if ($bad -eq 0) { 'PASS' } else { 'FAIL' }), $(if ($bad -eq 0) { $script:results.Count } else { $bad }), $script:results.Count)
exit $(if ($bad -eq 0) { 0 } else { 1 })
