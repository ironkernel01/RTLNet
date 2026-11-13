<#
-------------------------------------------------------------------------------
File: stream_test.ps1
Purpose: board gate of Phase 2b-3 and 2c: the H.264 encoder streams the color bars as
  MPEG-TS over UDP (an IDR picture every -Gop pictures, P pictures between), and this PC checks the stream with its own TS parser,
  ffprobe, ffmpeg and VLC.
Overview:
  * Takes the machine-wide board lock (rtlnet_board_lock.ps1) unless -NoBoard. Talks to the firmware CLI over the board
    USB-UART (115200 8N1) like phase1_gate.ps1. Tools through scripts/rtlnet_tools.ps1 (Resolve-RtlnetFfmpeg,
    Resolve-RtlnetVlc, Resolve-RtlnetPython).
  * For each mode (720p30, 1080p30, or both): "camera mode", "stream h264 <PC address> <port>", capture of the UDP datagrams
    on this PC for -Seconds with a .NET UDP socket (the datagrams are kept as received, so a lost datagram shows as a
    continuity error; ffmpeg's own udp:// reader remuxes and would hide it), "show stream" and "show encoder" from the
    board, "stream stop". Checks per mode, one result line each:
      ts      stream_check.py ts --gop: 188-byte packets, continuity counters, PAT and PMT CRC-32, PCR, PES, PTS and DTS equal,
              PTS steps of 3000, about 30 pictures per second, no PTS gaps, the random access indicator and the IDR NAL units
              exactly every -Gop pictures; the bytes per IDR and per P access unit (AU_SIZE lines)
      probe   ffprobe: one video stream, h264 Constrained Baseline, the right width and height, about 30 fps
      decode  ffmpeg decodes every picture (IDR and P); stream_check.py psnr compares every decoded yuv420p frame with the
              expected 4:2:0 color bars (same eight bars as rtlnet_csi2_rx); PSNR floor -PsnrFloor
      png     a decoded frame is written to boards/nexys_video/build/phase2c_gop<N>_decoded_<mode>.png
      board   show stream: pictures counted, no dropped pictures, no UDP drops, frame buffer drops reported, GOP and the IDR and
              P counts, clocks per macroblock of each engine (show encoder), TS-mux CPU load
  * VLC step (720p30 unless -SkipVlc): VLC starts on udp://@:<port> with the scene video filter, the board stream runs, and
    the first snapshot PNG is kept as boards/nexys_video/build/phase2c_gop<N>_vlc_snapshot.png.
  * If a capture receives no datagram while the board reports sent datagrams, the script prints the Windows firewall block
    and the command the user runs from an elevated prompt; it never changes the firewall.
  * Phase 2d (rate control and moving patterns): -Pattern <bars|scroll|box|noise|all> -Speed <n> ("camera pattern" before the stream), -Bitrate <kbps>
    and -BufferMs <ms> ("encoder bitrate", "encoder buffer"; without -Bitrate the encoder is set back to constant QP), -Tag <name> (file prefix
    phase2d_<name> instead of phase2c_gop<N>). With -Pattern the decoded pictures are compared with pattern_model.py (PSNR minimum and mean;
    the floor is 0 unless -PsnrFloor is given; -PsnrStep N checks every N-th picture of a long capture). With -Bitrate more checks run:
      rate    stream_check.py ts --target-kbps: after the first 2 s every sliding 1 s window (30 pictures) of the elementary stream within
              +-10 % of the target (10 s windows within +-3 % with -Gate10); the seconds at the top of the QP range are waived
      qp      slice QP of every picture parsed from the stream: the step between pictures is at most 2 (QP min, avg, max printed)
      history "show encoder history" of the board: the same 1 s and 10 s window checks on the board's own per-second records
    -Saturate low|high: the target is outside the reachable range (low: below, the encoder sits at the QP maximum; high: above, at the QP minimum); the
    rate windows are reported, and a result line checks that at least 90 % of the seconds sit at that QP limit.
    -CcTolPct P: continuity errors up to P percent of the packets pass (Wi-Fi; the default 0 is strict). -Jm: the stream is also decoded
    with the JM ldecod (clean, as many frames as access units, same pictures as FFmpeg when -PsnrStep is 1). The decode step also fails on
    any FFmpeg error message. A "RUN_SUMMARY" line gives target, measured rate, worst windows, QP and PSNR of each mode.
  * -PollSeconds <n>: during the capture read show encoder every n s (every 5 s near a license end; each read of show encoder blocks the firmware for 2 to 3 pictures, so a polled capture has dropped pictures: the license test of hp_expiry_test.ps1 does not poll) into <prefix>_<mode>_poll.txt (High profile license timer test).
  * -PollStream: with -PollSeconds, each poll also reads show stream (pictures sent and dropped, backlog) into the poll log. The board gate "pictures, drops, load" still requires 0 dropped pictures over the whole capture, so it covers the polls (Phase 2f: console output no longer blocks the firmware).
  * -Profile baseline|high: "encoder profile <name>" before the stream starts (the full High profile image, CABAC); with high the ffprobe step requires profile High
    (baseline: Constrained Baseline). -SwitchProfile: the capture starts in baseline, "encoder profile high" is sent one third into the capture and
    "encoder profile baseline" at two thirds; use -ForcedIdr 2 (one forced IDR picture at each switch); the ffprobe profile is not gated.
  * -Transform8x8 on|off|auto: "encoder transform8x8" before the stream starts; -SwitchTransform8x8: the capture starts with the 8x8 transform on, off is sent one third into the
    capture and auto at two thirds (two forced IDR pictures: on to off, off to auto). -Notify interrupt|polled: "encoder notify" before the stream starts; -SwitchNotify: the capture starts in
    interrupt mode, "encoder notify polled" is sent one third into the capture and "encoder notify interrupt" at two thirds; the stream must keep running with 0 dropped pictures.
  * -Deblock on|off: "encoder deblock" before the stream starts; -SwitchDeblock: the capture starts with the filter on, off is sent one third into the capture and on at two thirds (effective at the next
    picture, no forced IDR picture). The filter is set back to on after the run.
  * -IrqTest: three seconds after the stream start "encoder irqtest" is sent (a forced ring stall event must reach the interrupt handler); needs interrupt mode.
  * -ForcedIdr <n>: exactly n IDR pictures off the GOP cadence are expected (the forced IDR picture at the license end of the High profile demo netlist).
  * -LinkSpeed auto|100|1000: before the run (no stream running) the link is set from the console: 100 = "advertise 10f,100f" (auto-negotiation limited to 10/100, the
    PHY comes up at 100 Mb/s with this switch), auto and 1000 = "no advertise", "speed auto" (full 10/100/1000 negotiation); the script waits for the link (1000 must come
    up at 1000 Mb/s, 100 at 10 or 100) and for the DHCP lease, prints "show phy" and the link and lease times, and fails if the link or the lease does not return in 40 s.
    The setting stays after the run; set -LinkSpeed auto (or 1000) in a later run to restore it.
  * -InputTs <file>: check an existing capture offline (no board, no capture).
  * The transcript is boards/nexys_video/build/phase2c_gop<N>_stream_transcript.txt. The last line is
    "STREAM_TEST: PASS <n>/<n>" or "STREAM_TEST: FAIL <failed>/<n>"; exit code 0 only on PASS.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/stream_test.ps1 [-Mode both] [-Seconds 60]
    [-Port COM3] [-UdpPort 5004] [-HostIp <PC address>] [-Qp 28] [-Gop 30] [-Pattern all -Speed 4] [-Bitrate 2000 [-BufferMs 500]] [-Tag <name>] [-SkipVlc] [-NoBoard] [-LinkSpeed auto|100|1000] [-InputTs <file> -Width 1280 -Height 720]
Revision: 11-13-2026
  * 11-13-2026: -LinkSpeed (link speed from the console before the run, wait for link and DHCP lease).
  * 11-12-2026: -Deblock and -SwitchDeblock (encoder deblock).
  * 11-12-2026: -IrqTest.
  * 11-12-2026: -Transform8x8 auto, -SwitchTransform8x8 ends in auto (off, then auto), -Notify and -SwitchNotify (encoder notify), the transform request is set back to off (the firmware default) after the run.
  * 11-12-2026: -Transform8x8 on|off ("encoder transform8x8" before the stream starts; the full High profile image with the 8x8 transform) and -SwitchTransform8x8
    (the capture starts with the 8x8 transform on, "encoder transform8x8 off" is sent one third into the capture and "on" at two thirds; use -ForcedIdr 2 and -Profile high).
  * 11-11-2026: -PollSeconds (show encoder read during the capture).
  * 11-11-2026: -FilePrefix (file prefix of the logs, for example phase2e_rc1).
  * 11-09-2026: initial version.
  * 11-10-2026: Phase 2c: -Gop (encoder gop), file prefix phase2c_gop<N>, GOP and NAL checks in the TS parser, every decoded frame
    checked, IDR and P sizes, clocks per macroblock and TS-mux load in the board line.
  * 11-10-2026: Phase 2d: -Pattern, -Speed, -Bitrate, -BufferMs, -Tag, -PsnrStep, -Jm, -Gate10, -CcTolPct, bit-rate, QP-step, history and
    decode-error checks, RUN_SUMMARY line.
-------------------------------------------------------------------------------
#>
param(
    [ValidateSet('720p30', '1080p30', 'both')][string]$Mode = 'both',
    [int]$Seconds = 60,
    [string]$Port = 'COM3',
    [int]$Baud = 115200,
    [int]$UdpPort = 5004,
    [string]$HostIp = '',
    [int]$Qp = 28,
    [ValidateRange(1, 255)][int]$Gop = 30,
    [double]$PsnrFloor = 30.0,
    [int]$VlcSeconds = 14,
    [switch]$SkipVlc,
    [switch]$NoBoard,
    [string]$InputTs = '',
    [int]$Width = 1280,
    [int]$Height = 720,
    [int]$StepTimeoutMs = 8000,
    [ValidateSet('', 'bars', 'scroll', 'box', 'noise', 'all')][string]$Pattern = '',
    [ValidateRange(-32, 32)][int]$Speed = 4,
    [ValidateRange(0, 100000)][int]$Bitrate = 0,
    [ValidateRange(0, 2000)][int]$BufferMs = 0,
    [string]$Tag = '',
    [int]$PsnrStep = 1,
    [int]$KFirstMax = 200,
    [double]$CcTolPct = 0.0,
    [ValidateSet('', 'low', 'high')][string]$Saturate = '',
    [switch]$Gate10,
    [switch]$NoPing,
    [switch]$Jm,
    [string]$FilePrefix = '',
    [int]$PollSeconds = 0,
    [switch]$PollStream,
    [int]$ForcedIdr = -1,
    [ValidateSet('', 'baseline', 'high')][string]$Profile = '',
    [switch]$SwitchProfile,
    [ValidateSet('', 'on', 'off', 'auto')][string]$Transform8x8 = '',
    [switch]$SwitchTransform8x8,
    [ValidateSet('', 'interrupt', 'polled')][string]$Notify = '',
    [switch]$SwitchNotify,
    [ValidateSet('', 'on', 'off')][string]$Deblock = '',
    [switch]$SwitchDeblock,
    [switch]$IrqTest,
    [ValidateSet('', 'auto', '100', '1000')][string]$LinkSpeed = ''
)
$ErrorActionPreference = 'Stop'
$Repo  = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Build = Join-Path $Board 'build'
New-Item -ItemType Directory -Force -Path $Build | Out-Null
. (Join-Path $Repo 'scripts\rtlnet_tools.ps1')
$ff = Resolve-RtlnetFfmpeg
$py = Resolve-RtlnetPython
$Check = Join-Path $PSScriptRoot 'stream_check.py'
$Prefix = "phase2c_gop$Gop"
if ($Tag) { $Prefix = "phase2d_$Tag" }
if ($FilePrefix) { $Prefix = $FilePrefix }
$PatNum = @{ 'bars' = 0; 'scroll' = 1; 'box' = 2; 'noise' = 3; 'all' = 4 }
if (-not $PSBoundParameters.ContainsKey('PsnrFloor') -and $Pattern) { $PsnrFloor = 0.0 }
$script:waive = ''
$script:summary = @{}
$Transcript = Join-Path $Build "${Prefix}_stream_transcript.txt"
$script:log = New-Object System.Text.StringBuilder
$script:results = @()
$PromptRe = '(rtlnet(\([a-z-]+\))?[>#])$'

function Say([string]$s) { Write-Output $s; [void]$script:log.AppendLine($s) }
function Add-Result([string]$name, [bool]$ok, [string]$detail) {
    $script:results += [pscustomobject]@{ Step = $name; Ok = $ok; Detail = $detail }
    Say ("  {0,-4} {1,-44} {2}" -f ($(if ($ok) { 'ok' } else { 'FAIL' })), $name, $detail)
}

# Run a native program with its output in files (PowerShell 5.1: no stderr redirection under Stop). Returns the exit code.
function Invoke-Native([string]$exe, [string[]]$arguments, [string]$outFile, [string]$workDir = '') {
    $err = $outFile + '.err'
    if ($workDir) {
        $p = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $err -WorkingDirectory $workDir
    } else {
        $p = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $err
    }
    return $p.ExitCode
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

function Invoke-Cli($sp, [string]$line, [int]$timeoutMs = 0) {
    if ($timeoutMs -le 0) { $timeoutMs = $StepTimeoutMs }
    $sp.Write($line + "`r")
    $out = Read-UntilPrompt $sp $timeoutMs
    [void]$script:log.Append($out)
    return ($out -replace "`r", '')
}

# UDP capture: a native receiver thread (C#, compiled once with Add-Type) binds the port, drains the socket into a large buffered file write,
# and counts datagrams. A PowerShell job with one Receive and one unbuffered write per datagram can fall behind a 8 Mb/s burst (the first IDR
# picture of a GOP 1 stream) and lets the socket overflow; the thread has a 32 MB socket buffer and a 4 MB file buffer, and the script compares
# its count with the datagrams the board reports and with the Windows UDP "Receive Errors" counter.
if (-not ('RtlnetUdpCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Diagnostics;
public class RtlnetUdpCapture {
    Socket sock; Thread th; FileStream fs, lens; byte[] buf = new byte[65536];
    public long Datagrams, Bytes, Odd; public double FirstAt = -1, LastAt;
    double seconds; Stopwatch sw = new Stopwatch(); volatile bool stop;
    public double Seconds { get { return FirstAt < 0 ? 0 : LastAt - FirstAt; } }
    public void Start(int port, string file, double secs) {
        seconds = secs;
        sock = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        sock.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        sock.ReceiveBufferSize = 32 * 1024 * 1024;
        sock.Bind(new IPEndPoint(IPAddress.Any, port));
        fs = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.Read, 4 * 1024 * 1024);
        lens = new FileStream(file + ".lens", FileMode.Create, FileAccess.Write, FileShare.Read, 256 * 1024);
        sw.Start();
        th = new Thread(Run); th.IsBackground = true; th.Priority = ThreadPriority.AboveNormal; th.Start();
    }
    void Run() {
        while (!stop) {
            double now = sw.Elapsed.TotalSeconds;
            if (FirstAt < 0) { if (now > seconds + 25) break; } else if (now - FirstAt >= seconds) break;
            if (sock.Poll(200000, SelectMode.SelectRead)) {
                int n = sock.Receive(buf, 0, buf.Length, SocketFlags.None);
                double t = sw.Elapsed.TotalSeconds;
                if (FirstAt < 0) FirstAt = t;
                LastAt = t;
                fs.Write(buf, 0, n);
                lens.WriteByte((byte)(n & 255)); lens.WriteByte((byte)(n >> 8));
                Datagrams++; Bytes += n; if ((n % 188) != 0) Odd++;
            }
        }
        fs.Flush(); fs.Close(); lens.Flush(); lens.Close(); sock.Close();
    }
    public bool Join(int ms) { return th.Join(ms); }
    public void Abort() { stop = true; }
    public int RxBufferSize { get { return 0; } }
}
'@
}

function Get-UdpRxErrors {
    $t = (& netstat.exe -s -p udp) -join "`n"
    if ($t -match 'Receive Errors\s+=\s+(\d+)') { return [long]$Matches[1] }
    return -1
}

function Start-Capture([string]$file, [double]$seconds) {
    $cap = New-Object RtlnetUdpCapture
    $cap.Start($UdpPort, $file, $seconds)
    return $cap
}

# The checks on one captured transport stream file.
function Test-Capture([string]$tag, [string]$ts, [int]$w, [int]$h, [double]$fps) {
    $name = "${Prefix}_$tag"
    if (-not $InputTs) {
        # datagrams that arrived out of order (seen at stream start and at IDR bursts over Wi-Fi) are put back in order by their continuity counters
        if (Test-Path -LiteralPath ($ts + '.lens')) {
            $roOut = Join-Path $Build ($name + '_reorder.txt')
            [void](Invoke-Native $py @('-I', $Check, 'reorder', $ts, ($ts + '.lens')) $roOut)
            Say ((Get-Content -LiteralPath $roOut) -join ' ')
        }
        $trimOut = Join-Path $Build ($name + '_trim.txt')
        [void](Invoke-Native $py @('-I', $Check, 'trim', $ts) $trimOut)
        Say ((Get-Content -LiteralPath $trimOut) -join ' ')
    }
    # first datagrams of a stream lost over Wi-Fi (the first IDR picture, a burst larger than later ones): cut before the first IDR picture, reported
    if ($CcTolPct -gt 0) {
        $htOut = Join-Path $Build ($name + '_headtrim.txt')
        [void](Invoke-Native $py @('-I', $Check, 'headtrim', $ts) $htOut)
        Say ((Get-Content -LiteralPath $htOut) -join ' ')
    }
    $o = Join-Path $Build ($name + '_ts.txt')
    $tsArgs = @('-I', $Check, 'ts', $ts, '--fps', "$fps", '--gop', "$Gop", '--cc-tol-pct', "$CcTolPct")
    if ($ForcedIdr -ge 0) { $tsArgs += @('--forced-idr', "$ForcedIdr") }
    if ($Bitrate -gt 0) {
        $tsArgs += @('--target-kbps', "$Bitrate", '--skip-s', '2', '--max-qp-step', '2')
        if ($script:waive) { $tsArgs += @('--waive', $script:waive) }
        if ($Gate10) { $tsArgs += '--gate10' }
    }
    $rc = Invoke-Native $py $tsArgs $o
    $lines = @(Get-Content -LiteralPath $o)
    foreach ($l in $lines) { [void]$script:log.AppendLine($l) }
    $tsFail = @($lines | Where-Object { $_ -match '^CHECK \S+ FAIL' -and $_ -notmatch '^CHECK (rate_|qp_steps)' })
    $sum = ($lines | Where-Object { $_ -match '^TS_SUMMARY' } | Select-Object -Last 1)
    # with -Bitrate the exit code also carries the rate and QP checks, which have their own result lines
    $tsOk = $(if ($Bitrate -gt 0) { $tsFail.Count -eq 0 -and ($lines | Where-Object { $_ -match '^TS_SUMMARY' }) } else { $rc -eq 0 -and $tsFail.Count -eq 0 })
    Add-Result "$tag ts: parser checks" $tsOk ("$sum" + $(if ($tsFail.Count) { ' | ' + (($tsFail | ForEach-Object { $_.Substring(6, [Math]::Min(80, $_.Length - 6)) }) -join ' | ') } else { '' }))
    $script:summary['rate'] = (@($lines | Where-Object { $_ -match '^(RATE|QP) ' }) -join ' | ')
    if ($Bitrate -gt 0) {
        $rf = @($lines | Where-Object { $_ -match '^CHECK (rate_1s|rate_10s|qp_steps) ' })
        foreach ($l in $rf) { Add-Result "$tag $(($l -split ' ')[1])" (($l -match '^CHECK \S+ PASS') -or ($Saturate -and $l -notmatch 'qp_steps')) ($l -replace '^CHECK \S+ \S+ ', '') }
    }
    $acc = Get-Field ($lines -join "`n") 'access_units=(\d+)'
    $ccErr = [int](Get-Field ($lines -join "`n") 'cc_errors=(\d+)')
    $lostAu = [int](Get-Field ($lines -join "`n") 'LOST_AU (\d+)')
    $lossy = ($CcTolPct -gt 0 -and $ccErr -gt 0)
    # ffprobe
    $pj = Join-Path $Build ($name + '_probe.json')
    $rc = Invoke-Native $ff.Ffprobe @('-v', 'error', '-show_streams', '-show_format', '-of', 'json', $ts) $pj
    $probe = $null
    try { $probe = (Get-Content -LiteralPath $pj -Raw) | ConvertFrom-Json } catch { }
    $vs = @(); if ($probe) { $vs = @($probe.streams) }
    $okp = ($rc -eq 0 -and $vs.Count -eq 1 -and $vs[0].codec_name -eq 'h264' -and [int]$vs[0].width -eq $w -and [int]$vs[0].height -eq $h)
    $rate = 0.0
    if ($vs.Count -ge 1 -and $vs[0].avg_frame_rate -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -gt 0) { $rate = [int]$Matches[1] / [int]$Matches[2] }
    $okp = $okp -and ([Math]::Abs($rate - $fps) -lt 1.0)
    if ($Profile -eq 'high' -and -not $SwitchProfile) { $okp = $okp -and ($vs.Count -ge 1 -and $vs[0].profile -eq 'High') }
    if ($Profile -eq 'baseline' -and -not $SwitchProfile) { $okp = $okp -and ($vs.Count -ge 1 -and $vs[0].profile -eq 'Constrained Baseline') }
    Add-Result "$tag probe: stream, size, rate" $okp ("{0} stream(s), {1} {2} {3}x{4}, {5:N2} fps" -f $vs.Count, $(if ($vs.Count) { $vs[0].codec_name } else { '-' }), $(if ($vs.Count) { $vs[0].profile } else { '-' }), $(if ($vs.Count) { $vs[0].width } else { 0 }), $(if ($vs.Count) { $vs[0].height } else { 0 }), $rate)
    # decode and compare with the expected bars
    $yuv = Join-Path $Build ($name + '_decoded.yuv')
    $decFile = Join-Path $Build ($name + '_decode.txt')
    $decArgs = @('-v', 'error', '-y', '-i', $ts)
    if ($PsnrStep -gt 1) { $decArgs += @('-vf', "select=not(mod(n\,$PsnrStep))", '-fps_mode', 'passthrough') }
    $decArgs += @('-pix_fmt', 'yuv420p', '-f', 'rawvideo', $yuv)
    $rc = Invoke-Native $ff.Ffmpeg $decArgs $decFile
    $decErrLines = @(Get-Content -LiteralPath ($decFile + '.err') -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    # a capture with lost datagrams (Wi-Fi, within -CcTolPct) damages the access units next to the loss: FFmpeg messages are reported, not gated
    $decOk = ($rc -eq 0 -and $decErrLines.Count -eq 0) -or ($lossy -and $decErrLines.Count -gt 0 -and $decErrLines.Count -le (40 * $ccErr))
    Add-Result "$tag decode: FFmpeg messages" $decOk ("exit $rc, $($decErrLines.Count) error line(s)" + $(if ($decErrLines.Count) { ': ' + $decErrLines[0] } else { '' }) + $(if ($lossy -and $decErrLines.Count) { " (tolerated: $ccErr continuity errors, $lostAu lost access unit(s))" } else { '' }))
    $dmsg = ''
    $dok = $false
    if (Test-Path -LiteralPath $yuv) {
        $o2 = Join-Path $Build ($name + '_psnr.txt')
        $pa = @('-I', $Check, 'psnr', $yuv, "$w", "$h", '--floor', "$PsnrFloor", '--max-frames', '0')
        if ($Pattern -and $Pattern -ne 'bars') { $pa += @('--pattern', "$($PatNum[$Pattern])", '--speed', "$Speed", '--k-first-max', "$KFirstMax", '--step', "$PsnrStep") }
        $rc2 = Invoke-Native $py $pa $o2
        $pl = @(Get-Content -LiteralPath $o2)
        foreach ($l in $pl) { [void]$script:log.AppendLine($l) }
        $pc = ($pl | Where-Object { $_ -match '^CHECK psnr' } | Select-Object -Last 1)
        $stat = ($pl | Where-Object { $_ -match '^PSNR_STAT' } | Select-Object -Last 1)
        $kline = ($pl | Where-Object { $_ -match '^PSNR_K' } | Select-Object -Last 1)
        $script:summary['psnr'] = "$stat"
        if ($stat) { Say "$stat"; Say "$kline" }
        $dok = ($rc -eq 0 -and $rc2 -eq 0)
        $dmsg = "$pc"
        $dec = (Get-Item -LiteralPath $yuv).Length / ($w * $h * 3 / 2)
        $dmsg += " ($([int]$dec) frames)"
        if ($Jm) {
            $ld = Resolve-RtlnetLdecod
            if ($lossy) {
                Say "$tag jm: ldecod not gated, the capture has $ccErr continuity errors ($lostAu lost access unit(s)); JM does not decode across a lost datagram (gated on captures without continuity errors only)"
            } elseif (-not $ld) {
                Add-Result "$tag jm: ldecod" $false 'JM ldecod not found (set RTLNET_LDECOD)'
            } else {
                $jdir = Join-Path $Build ($name + '_jm')
                Remove-Item -LiteralPath $jdir -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -ItemType Directory -Force -Path $jdir | Out-Null
                $es = Join-Path $jdir 'stream.264'
                [void](Invoke-Native $ff.Ffmpeg @('-v', 'error', '-y', '-i', $ts, '-c:v', 'copy', '-f', 'h264', $es) (Join-Path $jdir 'extract.txt'))
                $jrc = Invoke-Native $ld @('-i', 'stream.264', '-o', 'dec_jm.yuv') (Join-Path $jdir 'jm.log') $jdir
                $jtext = ((Get-Content -LiteralPath (Join-Path $jdir 'jm.log') -ErrorAction SilentlyContinue) -join "`n") + ((Get-Content -LiteralPath (Join-Path $jdir 'jm.log.err') -ErrorAction SilentlyContinue) -join "`n")
                $jframes = [int](Get-Field $jtext '(\d+) frames are decoded')
                $jyuv = Join-Path $jdir 'dec_jm.yuv'
                $same = 'not compared'
                if ($PsnrStep -le 1 -and (Test-Path -LiteralPath $jyuv)) {
                    $same = $(if ((Get-FileHash -LiteralPath $jyuv -Algorithm MD5).Hash -eq (Get-FileHash -LiteralPath $yuv -Algorithm MD5).Hash) { 'identical to FFmpeg' } else { 'DIFFERENT from FFmpeg' })
                }
                $jok = ($jrc -eq 0 -and $jtext -notmatch '(?im)(\berror\b|out of range|corrupt|invalid)' -and $jframes -eq [int]$acc -and $same -ne 'DIFFERENT from FFmpeg')
                Add-Result "$tag jm: ldecod decode" $jok "exit $jrc, $jframes frames decoded of $acc access units, JM output $same"
                Remove-Item -LiteralPath $jyuv, $es -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $yuv -ErrorAction SilentlyContinue
    } else { $dmsg = 'ffmpeg produced no output' }
    Add-Result "$tag decode: PSNR against the $(if ($Pattern -and $Pattern -ne 'bars') { "pattern $Pattern (speed $Speed)" } else { 'bars' })" $dok $dmsg
    # PNG of a decoded frame
    $png = Join-Path $Build "${Prefix}_decoded_$tag" 
    $png = $png + '.png'
    Remove-Item -LiteralPath $png -ErrorAction SilentlyContinue
    [void](Invoke-Native $ff.Ffmpeg @('-v', 'error', '-y', '-i', $ts, '-vf', 'select=eq(n\,20)', '-fps_mode', 'passthrough', '-frames:v', '1', $png) (Join-Path $Build ($name + '_png.txt')))
    Add-Result "$tag png: decoded frame" ((Test-Path -LiteralPath $png) -and ((Get-Item -LiteralPath $png).Length -gt 1000)) $png
}

function Get-Field([string]$text, [string]$pattern) {
    if ($text -match $pattern) { return $Matches[1] }
    return $null
}

# Offline check of an existing capture.
if ($InputTs) {
    Say "STREAM_TEST offline: $InputTs ($Width x $Height)"
    Test-Capture 'offline' $InputTs $Width $Height 30.0
    $failed = @($script:results | Where-Object { -not $_.Ok }).Count
    Set-Content -LiteralPath $Transcript -Value ($script:log.ToString()) -Encoding ascii
    if ($failed -eq 0) { Say "STREAM_TEST: PASS $($script:results.Count)/$($script:results.Count)"; exit 0 }
    Say "STREAM_TEST: FAIL $failed/$($script:results.Count)"; exit 1
}

if (-not $NoBoard) {
    . (Join-Path $Repo 'scripts\rtlnet_board_lock.ps1')
    $nModes = $(if ($Mode -eq 'both') { 2 } else { 1 })
    Enter-RtlnetBoardLock -Purpose 'phase2c stream test' -ExpectedMinutes ([int][Math]::Ceiling($nModes * ($Seconds / 60.0 + 8)) + 30)
}
$modes = @($Mode); if ($Mode -eq 'both') { $modes = @('720p30', '1080p30') }
$dims = @{ '720p30' = @(1280, 720); '1080p30' = @(1920, 1080) }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.Handshake = [System.IO.Ports.Handshake]::None
$sp.ReadTimeout = 200
$sp.WriteTimeout = 2000
try { $sp.Open() } catch { Write-Output "STREAM_TEST: FAIL cannot open ${Port}: $($_.Exception.Message)"; exit 1 }
try {
    $sp.DiscardInBuffer()
    $sp.Write([string][char]3)
    $sp.Write("`r")
    $sync = Read-UntilPrompt $sp $StepTimeoutMs
    [void]$script:log.Append($sync)
    if (($sync -replace "`r", '').TrimEnd(' ') -notmatch $PromptRe) { Write-Output "STREAM_TEST: FAIL no prompt on $Port"; exit 1 }
    if ($Matches[1] -ne 'rtlnet>') { $sp.Write([string][char]26); [void](Read-UntilPrompt $sp $StepTimeoutMs); [void](Invoke-Cli $sp 'disable') }
    [void](Invoke-Cli $sp 'enable')
    [void](Invoke-Cli $sp 'stream stop')

    if ($LinkSpeed) {
        $want = $(if ($LinkSpeed -eq '100') { 100 } else { 1000 })
        [void](Invoke-Cli $sp 'configure terminal'); [void](Invoke-Cli $sp 'interface eth0')
        if ($LinkSpeed -eq '100') { [void](Invoke-Cli $sp 'advertise 10f,100f') } else { [void](Invoke-Cli $sp 'no advertise'); [void](Invoke-Cli $sp 'speed auto') }
        $swl = [System.Diagnostics.Stopwatch]::StartNew()
        [void](Invoke-Cli $sp 'end')
        $linkS = -1; $leaseS = -1; $mb = 0
        while ($swl.Elapsed.TotalSeconds -lt 40 -and $leaseS -lt 0) {
            $o = Invoke-Cli $sp 'show interfaces' 4000
            if ($o -match 'eth0 is up, (\d+) Mb/s') {
                $mb = [int]$Matches[1]
                if ($linkS -lt 0 -and (($LinkSpeed -eq '100' -and $mb -le 100) -or ($LinkSpeed -ne '100' -and $mb -eq $want) -or $LinkSpeed -eq 'auto')) { $linkS = $swl.Elapsed.TotalSeconds }
                if ($linkS -ge 0) {
                    $o2 = Invoke-Cli $sp 'show ip' 4000
                    if ($o2 -match 'Effective IPv4\s+: (\d+\.\d+\.\d+\.\d+) .*\(DHCP lease\)') { $leaseS = $swl.Elapsed.TotalSeconds }
                }
            }
            if ($leaseS -lt 0) { Start-Sleep -Milliseconds 300 }
        }
        Say (Invoke-Cli $sp 'show phy')
        Add-Result "link set to $LinkSpeed" (($linkS -ge 0) -and ($leaseS -ge 0)) ("$mb Mb/s, link after {0:N1} s, DHCP lease after {1:N1} s" -f $linkS, $leaseS)
        if ($linkS -lt 0 -or $leaseS -lt 0) { Write-Output "STREAM_TEST: FAIL link or DHCP lease did not return after -LinkSpeed $LinkSpeed"; exit 1 }
    }

    # Board address and the PC address on the same network.
    $ipOut = Invoke-Cli $sp 'show ip'
    $boardIp = Get-Field $ipOut 'Effective IPv4\s+: (\d+\.\d+\.\d+\.\d+)'
    if (-not $boardIp) { Write-Output "STREAM_TEST: FAIL the board has no IPv4 address (show ip)"; exit 1 }
    if (-not $HostIp) {
        $pre = ($boardIp -split '\.')[0..2] -join '.'
        $cand = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "$pre.*" })
        if ($cand.Count -gt 0) { $HostIp = $cand[0].IPAddress }
    }
    if (-not $HostIp) { Write-Output "STREAM_TEST: FAIL no PC address on the board's network $boardIp; pass -HostIp"; exit 1 }
    Say "Board $boardIp, PC $HostIp, UDP port $UdpPort, QP $Qp, GOP $Gop, $Seconds s per mode, pattern $(if ($Pattern) { "$Pattern speed $Speed" } else { 'bars (default)' }), bit rate $(if ($Bitrate) { "$Bitrate kb/s" } else { 'constant QP' })"
    [void](Invoke-Cli $sp "encoder qp $Qp")
    if ($Bitrate -gt 0) {
        $br = Invoke-Cli $sp "encoder bitrate $Bitrate"
        Add-Result 'encoder bitrate set' ($br -match "Constant bit rate $Bitrate kb/s") ($br.Trim() -replace '\s+', ' ')
        $bufMs = $(if ($BufferMs -gt 0) { $BufferMs } else { 500 })
        $bm = Invoke-Cli $sp "encoder buffer $bufMs"
        Add-Result 'encoder buffer set' ($bm -match "buffer $bufMs ms") ($bm.Trim() -replace '\s+', ' ')
        [void](Invoke-Cli $sp 'encoder qprange 12 51')
    } else {
        [void](Invoke-Cli $sp 'encoder bitrate 0')
    }
    $g = Invoke-Cli $sp "encoder gop $Gop"
    Add-Result 'encoder gop set' ($g -match "GOP $Gop ") ($g.Trim() -replace '\s+', ' ')

    foreach ($m in $modes) {
        $w = $dims[$m][0]; $h = $dims[$m][1]
        Say "--- mode $m"
        [void](Invoke-Cli $sp "camera mode $m")
        Start-Sleep -Milliseconds 1500
        [void](Invoke-Cli $sp 'clear counters')
        $capFile = Join-Path $Build "${Prefix}_capture_$m.ts"
        # The board's ARP entry for this PC can be stale: the first datagrams of a stream then wait in lwIP's ARP queue (8 packets) and are lost or
        # delivered out of order. Two pings refresh the entry (-NoPing leaves it out, for the comparison).
        if (-not $NoPing) { $null = & ping.exe -n 2 -w 1000 $boardIp }
        $rx0 = Get-UdpRxErrors
        $capObj = Start-Capture $capFile ($Seconds + 0.0)
        # The pattern counter k restarts at the pattern write: write it right before the stream starts (k of the first picture stays small).
        $patName = $(if ($Pattern) { $Pattern } else { 'bars' })
        $pr = Invoke-Cli $sp "camera pattern $patName $Speed"
        Add-Result "$m pattern set" ($pr -match "Test pattern $patName, speed $Speed") ($pr.Trim() -replace '\s+', ' ')
        [void](Invoke-Cli $sp 'clear counters')
        $pfWanted = $(if ($SwitchProfile) { 'baseline' } else { $Profile })
        if ($pfWanted) {
            $pfr = Invoke-Cli $sp "encoder profile $pfWanted"
            Add-Result "$m encoder profile $pfWanted" ($pfr -match "Profile $pfWanted") ($pfr.Trim() -replace '\s+', ' ')
        }
        $t8Wanted = $(if ($SwitchTransform8x8) { 'on' } else { $Transform8x8 })
        if ($t8Wanted) {
            $t8r = Invoke-Cli $sp "encoder transform8x8 $t8Wanted"
            Add-Result "$m encoder transform8x8 $t8Wanted" ($t8r -match "Transform8x8 $t8Wanted") ($t8r.Trim() -replace '\s+', ' ')
        }
        $dbWanted = $(if ($SwitchDeblock) { 'on' } else { $Deblock })
        if ($dbWanted) {
            $dbr = Invoke-Cli $sp "encoder deblock $dbWanted"
            Add-Result "$m encoder deblock $dbWanted" ($dbr -match "Deblock $dbWanted,") ($dbr.Trim() -replace '\s+', ' ')
        }
        $nfWanted = $(if ($SwitchNotify) { 'interrupt' } else { $Notify })
        if ($nfWanted) {
            $nfr = Invoke-Cli $sp "encoder notify $nfWanted"
            Add-Result "$m encoder notify $nfWanted" ($nfr -match "Notification $nfWanted") ($nfr.Trim() -replace '\s+', ' ')
        }
        $tA = [int64]([DateTimeOffset](Get-Date)).ToUnixTimeMilliseconds()
        $r = Invoke-Cli $sp "stream h264 $HostIp $UdpPort"
        $tB = [int64]([DateTimeOffset](Get-Date)).ToUnixTimeMilliseconds()
        Say "STREAM_START_EPOCH_MS $tA $tB (host time before and after the stream start command)"
        Add-Result "$m stream start" ($r -match 'Streaming H.264') ($r.Trim() -replace '\s+', ' ')
        if ($IrqTest) {
            # Interrupt self test with the stream running (interrupt mode): a forced ring stall event must reach the handler.
            Start-Sleep -Seconds 3
            $irr = Invoke-Cli $sp 'encoder irqtest'
            Add-Result "$m encoder irqtest" ($irr -match 'Interrupt test passed') ($irr.Trim() -replace '\s+', ' ')
        }
        if ($PollSeconds -gt 0) {
            # License-timer test: read "show encoder" every -PollSeconds s while the capture runs (every 5 s while 90 s or less are left and for 40 s after
            # the end), one line per read with the host time, into <prefix>_poll.txt.
            $pollLog = Join-Path $Build "${Prefix}_${m}_poll.txt"
            Set-Content -LiteralPath $pollLog -Value "# host_time epoch_ms | High profile line of show encoder | picture counters" -Encoding ascii
            $deadline = (Get-Date).AddSeconds($Seconds + 40)
            $wait = 5.0
            $endedAt = $null
            while ((Get-Date) -lt $deadline) {
                if ($capObj.Join([int]($wait * 1000))) { break }
                $tp = Get-Date
                $epoch = [int64]([DateTimeOffset]$tp).ToUnixTimeMilliseconds()
                $pr2 = Invoke-Cli $sp 'show encoder'
                $hpl = Get-Field $pr2 'High profile\s+: ([^\r\n]*)'
                $pl = Get-Field $pr2 'Pictures\s+: ([^\r\n]*)'
                if ($PollStream) {
                    $pr3 = Invoke-Cli $sp 'show stream'
                    $pl = $pl + ' || stream ' + (Get-Field $pr3 'Pictures\s+: ([^\r\n]*)') + ' || ' + (Get-Field $pr3 'Mux backlog\s+: ([^\r\n]*)')
                }
                Add-Content -LiteralPath $pollLog -Value ("{0:yyyy-MM-dd HH:mm:ss.fff} {1} | {2} | {3}" -f $tp, $epoch, $hpl, $pl) -Encoding ascii
                $wait = [double]$PollSeconds
                if ($hpl -match 'time left (\d+) min (\d+) s') { if ([int]$Matches[1] * 60 + [int]$Matches[2] -le 90) { $wait = 5.0 } }
                if ($hpl -match 'license ended') { if ($null -eq $endedAt) { $endedAt = $tp }; if (($tp - $endedAt).TotalSeconds -lt 40) { $wait = 5.0 } }
            }
        }
        if ($SwitchProfile) {
            # Profile switch in mid-stream: high at one third, baseline at two thirds of the capture.
            [void]$capObj.Join([int]($Seconds * 1000 / 3))
            $pfr = Invoke-Cli $sp 'encoder profile high'
            Add-Result "$m profile switch to high" ($pfr -match 'Profile high') ($pfr.Trim() -replace '\s+', ' ')
            [void]$capObj.Join([int]($Seconds * 1000 / 3))
            $pfr = Invoke-Cli $sp 'encoder profile baseline'
            Add-Result "$m profile switch to baseline" ($pfr -match 'Profile baseline') ($pfr.Trim() -replace '\s+', ' ')
        }
        if ($SwitchTransform8x8) {
            # 8x8 transform switch in mid-stream: off at one third, auto at two thirds of the capture.
            [void]$capObj.Join([int]($Seconds * 1000 / 3))
            $t8r = Invoke-Cli $sp 'encoder transform8x8 off'
            Add-Result "$m transform8x8 switch to off" ($t8r -match 'Transform8x8 off') ($t8r.Trim() -replace '\s+', ' ')
            [void]$capObj.Join([int]($Seconds * 1000 / 3))
            $t8r = Invoke-Cli $sp 'encoder transform8x8 auto'
            Add-Result "$m transform8x8 switch to auto" ($t8r -match 'Transform8x8 auto') ($t8r.Trim() -replace '\s+', ' ')
        }
        if ($SwitchDeblock) {
            # Deblocking filter switch in mid-stream: off at one third, on at two thirds of the capture (effective at the next picture, no IDR picture).
            [void]$capObj.Join([int]($Seconds * 1000 / 3))
            $dbr = Invoke-Cli $sp 'encoder deblock off'
            Add-Result "$m deblock switch to off" ($dbr -match 'Deblock off,') ($dbr.Trim() -replace '\s+', ' ')
            [void]$capObj.Join([int]($Seconds * 1000 / 3))
            $dbr = Invoke-Cli $sp 'encoder deblock on'
            Add-Result "$m deblock switch to on" ($dbr -match 'Deblock on,') ($dbr.Trim() -replace '\s+', ' ')
        }
        if ($SwitchNotify) {
            # Notification switch in mid-stream: polled at one third, interrupt at two thirds of the capture; the stream keeps running.
            [void]$capObj.Join([int]($Seconds * 1000 / 3))
            $nfr = Invoke-Cli $sp 'encoder notify polled'
            Start-Sleep -Seconds 1
            $nfs = Invoke-Cli $sp 'show stream'
            Add-Result "$m notify switch to polled" (($nfr -match 'Notification polled') -and ($nfs -match 'Notification\s+: polled')) (($nfr.Trim() -replace '\s+', ' ') + ' | ' + (Get-Field $nfs 'Notification\s+: ([^\r\n]*)'))
            [void]$capObj.Join([int]($Seconds * 1000 / 3))
            $nfr = Invoke-Cli $sp 'encoder notify interrupt'
            Start-Sleep -Seconds 1
            $nfs = Invoke-Cli $sp 'show stream'
            Add-Result "$m notify switch to interrupt" (($nfr -match 'Notification interrupt') -and ($nfs -match 'Notification\s+: interrupt')) (($nfr.Trim() -replace '\s+', ' ') + ' | ' + (Get-Field $nfs 'Notification\s+: ([^\r\n]*)'))
        }
        if (-not $capObj.Join(($Seconds + 40) * 1000)) { $capObj.Abort(); [void]$capObj.Join(5000) }
        $cap = [pscustomobject]@{ Datagrams = $capObj.Datagrams; Bytes = $capObj.Bytes; Seconds = $capObj.Seconds; Odd = $capObj.Odd }
        $rxErr = (Get-UdpRxErrors) - $rx0
        $ss = Invoke-Cli $sp 'show stream'
        $se = Invoke-Cli $sp 'show encoder'
        $sf = Invoke-Cli $sp 'show framebuffer'
        $sd = Invoke-Cli $sp 'show ddr'
        if ($sd -notmatch 'Master 3') { Start-Sleep -Milliseconds 700; [void]$sp.ReadExisting(); $sd = Invoke-Cli $sp 'show ddr' }   # the previous command's late prompt can end the read early
        [void](Invoke-Cli $sp 'stream stop')
        if ($Profile -or $SwitchProfile) { [void](Invoke-Cli $sp 'encoder profile baseline') }   # leave the board in the default profile
        if ($Transform8x8 -or $SwitchTransform8x8) { [void](Invoke-Cli $sp 'encoder transform8x8 off') }   # and with the default transform request (the 4x4 transform)
        if ($Deblock -or $SwitchDeblock) { [void](Invoke-Cli $sp 'encoder deblock on') }   # and with the filter on (the firmware default)
        if ($Notify -or $SwitchNotify) { [void](Invoke-Cli $sp 'encoder notify interrupt') }   # and in the default notification mode
        $histN = [Math]::Min(3600, $Seconds + 15)
        $sh = Invoke-Cli $sp "show encoder history $histN" 120000
        Set-Content -LiteralPath (Join-Path $Build "${Prefix}_${m}_history.txt") -Value ($sh -replace "`r", '') -Encoding ascii
        Say $ss.Trim()
        Say $se.Trim()
        $capDatagrams = 0; $capBytes = 0
        if ($cap) { $capDatagrams = $cap.Datagrams; $capBytes = $cap.Bytes }
        Say ("PC capture: {0} datagrams, {1} bytes, {2:N1} s, {3} datagrams not a multiple of 188 bytes" -f $capDatagrams, $capBytes, $(if ($cap) { $cap.Seconds } else { 0 }), $(if ($cap) { $cap.Odd } else { 0 }))
        $boardDg = [int](Get-Field $ss 'TS packets\s+: \d+ in (\d+) datagrams')
        Say ("PC receive: {0} datagrams, board counted {1} datagrams sent (read after the capture ended, so the board count may be a few higher), Windows UDP receive errors during the capture {2}" -f $capDatagrams, $boardDg, $rxErr)
        $sentDg = [int](Get-Field $ss 'UDP sent (\d+)')
        if ($capDatagrams -eq 0 -and $sentDg -gt 0) {
            Say "FIREWALL: the PC received no UDP datagram on port $UdpPort while the board sent $sentDg. The Windows firewall most likely blocks inbound UDP $UdpPort."
            Say "Run once from an elevated PowerShell (this script does not change the firewall):"
            Say "  New-NetFirewallRule -DisplayName 'RTLNet video UDP $UdpPort in' -Direction Inbound -Protocol UDP -LocalPort $UdpPort -Action Allow -Profile Any"
        }
        # Board-side facts
        $pics = [int](Get-Field $ss 'Pictures\s+: (\d+) sent')
        $drop = [int](Get-Field $ss 'sent, (\d+) dropped')
        $udpDrop = [int](Get-Field $ss 'UDP sent \d+, dropped (\d+)')
        $mux = Get-Field $ss 'TS mux (\d+\.\d) %'
        $busy = Get-Field $ss 'handling and mux (\d+\.\d) %'
        $kbps = Get-Field $ss 'bit rate (\d+) kb/s'
        $errs = [int](Get-Field $ss 'Errors\s+: (\d+);')
        $nIdr = [int](Get-Field $ss 'GOP\s+: \d+ \(IDR every \d+ pictures\); (\d+) IDR pictures')
        $nP = [int](Get-Field $ss 'IDR pictures \(\d+ bytes each on average\), (\d+) P pictures')
        $avgIdr = [int](Get-Field $ss '\); \d+ IDR pictures \((\d+) bytes each')
        $avgP = [int](Get-Field $ss 'P pictures \((\d+) bytes each')
        $lastType = Get-Field $se 'last picture (IDR|P)'
        $perMb = @([regex]::Matches($se, 'Engine \d\s+: \d+ macroblocks, picture \d+ cycles \((\d+) per macroblock\)') | ForEach-Object { $_.Groups[1].Value })
        $fbDrop = [int](Get-Field $sf 'dropped (\d+)')
        $fbDropShow = Get-Field $ss 'frame buffer published \d+, dropped (\d+)'
        # Rate control on the board: the per-second records (oldest first), windows against the target, the seconds at the top of the QP range waived.
        $rcLine = Get-Field $ss '(Rate control\s+: [^\n]*)'
        $qpMax = [int](Get-Field $ss 'QP range \d+\.\.(\d+)')
        $qpMin = [int](Get-Field $ss 'QP range (\d+)\.\.\d+')
        if ($qpMax -le 0) { $qpMax = 51 }
        if ($qpMin -le 0) { $qpMin = 12 }
        $ovf = Get-Field $ss '(Buffer events\s+: [^\n]*)'
        $qpLine = Get-Field $ss '(Picture QP\s+: [^\n]*)'
        $fillLine = Get-Field $ss '(Buffer fill\s+: [^\n]*)'
        $recs = @()
        foreach ($hl in ($sh -split "`n")) {
            if ($hl -match '^\s+(\d+)\s+(\d+)\s+(\d+)\.(\d+)\s+(\d+)\s+(\d+)\s*$') {
                $recs += [pscustomobject]@{ Age = [int]$Matches[1]; Bits = [double]$Matches[2]; Qp = [double]("$($Matches[3]).$($Matches[4])"); Fill = [int]$Matches[5]; Pics = [int]$Matches[6] }
            }
        }
        $script:waive = ''
        $hist1 = ''; $hist10 = ''
        if ($Bitrate -gt 0) {
            $wl = @()
            for ($i = 0; $i -lt $recs.Count; $i++) { if ($recs[$i].Qp -ge ($qpMax - 0.5) -or $recs[$i].Qp -le ($qpMin + 0.5)) { $wl += $i } }
            $script:waive = ($wl -join ',')
            $tgtBits = $Bitrate * 1000.0
            # records 0 and 1 (start-up) and the last one are left out; windows touching a waived second are skipped
            $worst1 = 0.0; $n1 = 0; $sk1 = 0
            for ($i = 2; $i -lt $recs.Count - 1; $i++) {
                if ($wl -contains $i) { $sk1++; continue }
                $d = [Math]::Abs($recs[$i].Bits - $tgtBits) / $tgtBits * 100.0
                if ($d -gt $worst1) { $worst1 = $d }
                $n1++
            }
            $worst10 = 0.0; $n10 = 0; $sk10 = 0
            for ($i = 2; $i + 10 -le $recs.Count - 1; $i++) {
                $hit = $false; for ($j = $i; $j -lt $i + 10; $j++) { if ($wl -contains $j) { $hit = $true } }
                if ($hit) { $sk10++; continue }
                $sum = 0.0; for ($j = $i; $j -lt $i + 10; $j++) { $sum += $recs[$j].Bits }
                $d = [Math]::Abs($sum - 10.0 * $tgtBits) / (10.0 * $tgtBits) * 100.0
                if ($d -gt $worst10) { $worst10 = $d }
                $n10++
            }
            $hist1 = ('{0:N2}' -f $worst1); $hist10 = ('{0:N2}' -f $worst10)
            Add-Result "$m history: 1 s records within +-10 %" ($Saturate -or ($n1 -gt 0 -and $worst1 -le 10.0)) ("target $Bitrate kb/s: worst of $n1 records deviates $hist1 % ($sk1 waived at the QP limits $qpMin and $qpMax, $($recs.Count) records)$(if ($Saturate) { ' (reported, not gated: saturated case)' })")
            if ($Saturate) {
                $want = $(if ($Saturate -eq 'low') { $qpMax } else { $qpMin })
                $satN = 0; $totN = 0
                for ($i = 2; $i -lt $recs.Count - 1; $i++) { $totN++; if ([Math]::Abs($recs[$i].Qp - $want) -le 0.5) { $satN++ } }
                Add-Result "$m saturation: QP at the $(if ($Saturate -eq 'low') { 'maximum' } else { 'minimum' }) $want" ($totN -gt 0 -and $satN -ge 0.9 * $totN) "$satN of $totN one-second records at QP $want (target $Bitrate kb/s is $(if ($Saturate -eq 'low') { 'below' } else { 'above' }) the reachable range); the rate is reported, not gated"
            }
            if ($Gate10) {
                Add-Result "$m history: 10 s windows within +-3 %" ($n10 -gt 0 -and $worst10 -le 3.0) ("worst of $n10 windows deviates $hist10 % ($sk10 waived)")
            } else {
                Say ("history 10 s windows: worst of {0} deviates {1} % ({2} waived; not gated)" -f $n10, $hist10, $sk10)
            }
            Say $rcLine
            Say $fillLine
            Say $qpLine
            Say $ovf
        }
        Add-Result "$m board: pictures, drops, load" ($pics -ge ($Seconds * 25) -and $drop -eq 0 -and $udpDrop -eq 0 -and $errs -eq 0) `
            "pictures $pics, dropped pictures $drop, UDP drops $udpDrop, errors $errs, bit rate $kbps kb/s, TS mux load $mux %, handling+mux $busy %, frame buffer drops $fbDropShow"
        $gopOk = ($nIdr + $nP -eq $pics) -and ($(if ($Gop -eq 1) { $nP -eq 0 } else { $nP -gt 0 -and $nIdr -ge [Math]::Floor($pics / $Gop) -and $nIdr -le ([Math]::Ceiling($pics / $Gop) + 1) }))
        Add-Result "$m gop: IDR and P pictures" $gopOk "GOP $Gop, $nIdr IDR pictures ($avgIdr bytes each), $nP P pictures ($avgP bytes each), last picture $lastType"
        Say ("{0}: clocks per macroblock per engine (last picture {1}): {2} (budget 735)" -f $m, $lastType, ($perMb -join ' and '))
        $armErr = @([regex]::Matches($sd, 'errors (\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Where-Object { $_ -ne 0 })
        Add-Result "$m show ddr: arbiter errors" ($armErr.Count -eq 0 -and $sd -match 'Master 3') "all masters errors 0"
        if ($capDatagrams -gt 0) {
            $script:summary = @{}
            Test-Capture $m $capFile $w $h 30.0
            $mean = $recs | Measure-Object -Property Bits -Average
            Say ("RUN_SUMMARY {0} pattern {1} speed {2} gop {3} target {4} kb/s | board 1s {5} kb/s, 10s {6} kb/s, history worst 1s {7} % 10s {8} % | pc: {9} | {10} | {11} | {12}" -f `
                $m, $(if ($Pattern) { $Pattern } else { 'bars' }), $Speed, $Gop, $Bitrate, (Get-Field $ss 'Measured rate\s+: (\d+) kb/s over the last 1 s'), (Get-Field $ss 'kb/s over the last 1 s, (\d+) kb/s over the last 10 s'), $hist1, $hist10, $script:summary['rate'], $script:summary['psnr'], $qpLine, $ovf)
        } else {
            Add-Result "$m capture" $false "no datagram received"
        }
    }

    if (-not $SkipVlc) {
        $vlc = Resolve-RtlnetVlc
        if (-not $vlc) {
            Add-Result 'vlc: found' $false 'VLC not found (set RTLNET_VLC)'
        } else {
            Say '--- VLC'
            [void](Invoke-Cli $sp 'camera mode 720p30')
            Start-Sleep -Milliseconds 1500
            $snapDir = Join-Path $Build "${Prefix}_vlc"
            Remove-Item -LiteralPath $snapDir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
            $vargs = @('--no-video-title-show', '--video-filter=scene', '--scene-format=png', '--scene-prefix=vlc_', "--scene-path=$snapDir",
                       '--scene-ratio=30', "udp://@:$UdpPort", '--run-time=' + $VlcSeconds, 'vlc://quit')
            $vp = Start-Process -FilePath $vlc -ArgumentList $vargs -PassThru -WindowStyle Hidden
            Start-Sleep -Seconds 3
            $r = Invoke-Cli $sp "stream h264 $HostIp $UdpPort"
            $null = $vp.WaitForExit(($VlcSeconds + 25) * 1000)
            if (-not $vp.HasExited) { Stop-Process -Id $vp.Id -Force }
            [void](Invoke-Cli $sp 'stream stop')
            $snaps = @(Get-ChildItem -LiteralPath $snapDir -Filter '*.png' -ErrorAction SilentlyContinue | Sort-Object Name)
            if ($snaps.Count -gt 0) {
                $pick = $snaps[[Math]::Min(2, $snaps.Count - 1)]
                Copy-Item -LiteralPath $pick.FullName -Destination (Join-Path $Build "${Prefix}_vlc_snapshot.png") -Force
            }
            Add-Result 'vlc: plays udp stream, snapshot' ($snaps.Count -gt 0) ("$($snaps.Count) snapshot(s) in $snapDir; kept ${Prefix}_vlc_snapshot.png")
        }
    }
    [void](Invoke-Cli $sp 'camera mode 720p30')
    [void](Invoke-Cli $sp 'camera pattern bars 4')
    [void](Invoke-Cli $sp 'encoder bitrate 0')
    [void](Invoke-Cli $sp 'encoder gop 30')
    [void](Invoke-Cli $sp 'disable')
} finally {
    $sp.Close()
}

Set-Content -LiteralPath $Transcript -Value ($script:log.ToString() -replace "`r`n", "`n" -replace "`r", '') -Encoding ascii
$failed = @($script:results | Where-Object { -not $_.Ok }).Count
$total = $script:results.Count
if ($failed -eq 0 -and $total -gt 0) {
    Write-Output "STREAM_TEST: PASS $total/$total"
    exit 0
}
Write-Output "STREAM_TEST: FAIL $failed/$total"
exit 1
