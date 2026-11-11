<#
-------------------------------------------------------------------------------
File: stream_test.ps1
Purpose: board gate of Phase 2b-3 and 2c (documentation/gige.md sections 14 and 17): the H.264 encoder streams the color bars as
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
  * -InputTs <file>: check an existing capture offline (no board, no capture).
  * The transcript is boards/nexys_video/build/phase2c_gop<N>_stream_transcript.txt. The last line is
    "STREAM_TEST: PASS <n>/<n>" or "STREAM_TEST: FAIL <failed>/<n>"; exit code 0 only on PASS.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/stream_test.ps1 [-Mode both] [-Seconds 60]
    [-Port COM3] [-UdpPort 5004] [-HostIp <PC address>] [-Qp 28] [-Gop 30] [-SkipVlc] [-NoBoard] [-InputTs <file> -Width 1280 -Height 720]
Revision: 11-10-2026
  * 11-09-2026: initial version.
  * 11-10-2026: Phase 2c: -Gop (encoder gop), file prefix phase2c_gop<N>, GOP and NAL checks in the TS parser, every decoded frame
    checked, IDR and P sizes, clocks per macroblock and TS-mux load in the board line.
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
$Check = Join-Path $PSScriptRoot 'stream_check.py'
$Prefix = "phase2c_gop$Gop"
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
function Invoke-Native([string]$exe, [string[]]$arguments, [string]$outFile) {
    $err = $outFile + '.err'
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $err
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

# UDP capture job: binds the port, signals ready through a file, writes every datagram to the capture file.
$captureScript = {
    param([int]$port, [string]$file, [string]$ready, [double]$seconds)
    $u = New-Object System.Net.Sockets.UdpClient
    $u.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $u.Client.ReceiveBufferSize = 16MB
    $u.Client.Bind((New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), $port))
    $fs = [System.IO.File]::Create($file)
    $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
    Set-Content -LiteralPath $ready -Value 'ready'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $count = 0; $bytes = 0; $first = -1.0; $last = 0.0; $odd = 0
    while ($true) {
        $limit = $seconds
        if ($first -lt 0) { $limit = $seconds + 20 }   # wait for the first datagram, then capture for the full time
        $now = $sw.Elapsed.TotalSeconds
        if ($first -lt 0) { if ($now -gt 25) { break } } elseif (($now - $first) -ge $seconds) { break }
        if ($u.Client.Poll(200000, [System.Net.Sockets.SelectMode]::SelectRead)) {
            $d = $u.Receive([ref]$ep)
            if ($first -lt 0) { $first = $sw.Elapsed.TotalSeconds }
            $last = $sw.Elapsed.TotalSeconds
            $fs.Write($d, 0, $d.Length)
            $count++; $bytes += $d.Length
            if (($d.Length % 188) -ne 0) { $odd++ }
        }
    }
    $fs.Close(); $u.Close()
    return [pscustomobject]@{ Datagrams = $count; Bytes = $bytes; Seconds = ($last - $first); Odd = $odd }
}

function Start-Capture([string]$file, [double]$seconds) {
    $ready = $file + '.ready'
    Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
    $job = Start-Job -ScriptBlock $captureScript -ArgumentList $UdpPort, $file, $ready, $seconds
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ready) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 100 }
    return $job
}

# The checks on one captured transport stream file.
function Test-Capture([string]$tag, [string]$ts, [int]$w, [int]$h, [double]$fps) {
    $name = "${Prefix}_$tag"
    $o = Join-Path $Build ($name + '_ts.txt')
    $rc = Invoke-Native $py @('-I', $Check, 'ts', $ts, '--fps', "$fps", '--gop', "$Gop") $o
    $lines = @(Get-Content -LiteralPath $o)
    foreach ($l in $lines) { [void]$script:log.AppendLine($l) }
    $tsFail = @($lines | Where-Object { $_ -match '^CHECK \S+ FAIL' })
    $sum = ($lines | Where-Object { $_ -match '^TS_SUMMARY' } | Select-Object -Last 1)
    Add-Result "$tag ts: parser checks" ($rc -eq 0 -and $tsFail.Count -eq 0) ("$sum" + $(if ($tsFail.Count) { ' | ' + (($tsFail | ForEach-Object { $_.Substring(6, [Math]::Min(80, $_.Length - 6)) }) -join ' | ') } else { '' }))
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
    Add-Result "$tag probe: stream, size, rate" $okp ("{0} stream(s), {1} {2} {3}x{4}, {5:N2} fps" -f $vs.Count, $(if ($vs.Count) { $vs[0].codec_name } else { '-' }), $(if ($vs.Count) { $vs[0].profile } else { '-' }), $(if ($vs.Count) { $vs[0].width } else { 0 }), $(if ($vs.Count) { $vs[0].height } else { 0 }), $rate)
    # decode and compare with the expected bars
    $yuv = Join-Path $Build ($name + '_decoded.yuv')
    $rc = Invoke-Native $ff.Ffmpeg @('-v', 'error', '-y', '-i', $ts, '-pix_fmt', 'yuv420p', '-f', 'rawvideo', $yuv) (Join-Path $Build ($name + '_decode.txt'))
    $dmsg = ''
    $dok = $false
    if (Test-Path -LiteralPath $yuv) {
        $o2 = Join-Path $Build ($name + '_psnr.txt')
        $rc2 = Invoke-Native $py @('-I', $Check, 'psnr', $yuv, "$w", "$h", '--floor', "$PsnrFloor", '--max-frames', '0') $o2
        $pl = @(Get-Content -LiteralPath $o2)
        foreach ($l in $pl) { [void]$script:log.AppendLine($l) }
        $pc = ($pl | Where-Object { $_ -match '^CHECK psnr' } | Select-Object -Last 1)
        $dok = ($rc -eq 0 -and $rc2 -eq 0)
        $dmsg = "$pc"
        $dec = (Get-Item -LiteralPath $yuv).Length / ($w * $h * 3 / 2)
        $dmsg += " ($([int]$dec) frames)"
        Remove-Item -LiteralPath $yuv -ErrorAction SilentlyContinue
    } else { $dmsg = 'ffmpeg produced no output' }
    Add-Result "$tag decode: PSNR against the bars" $dok $dmsg
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
    Enter-RtlnetBoardLock -Purpose 'phase2c stream test' -ExpectedMinutes 30
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
    Say "Board $boardIp, PC $HostIp, UDP port $UdpPort, QP $Qp, GOP $Gop, $Seconds s per mode"
    [void](Invoke-Cli $sp "encoder qp $Qp")
    $g = Invoke-Cli $sp "encoder gop $Gop"
    Add-Result 'encoder gop set' ($g -match "GOP $Gop ") ($g.Trim() -replace '\s+', ' ')

    foreach ($m in $modes) {
        $w = $dims[$m][0]; $h = $dims[$m][1]
        Say "--- mode $m"
        [void](Invoke-Cli $sp "camera mode $m")
        Start-Sleep -Milliseconds 1500
        [void](Invoke-Cli $sp 'clear counters')
        $capFile = Join-Path $Build "${Prefix}_capture_$m.ts"
        $job = Start-Capture $capFile ($Seconds + 0.0)
        $r = Invoke-Cli $sp "stream h264 $HostIp $UdpPort"
        Add-Result "$m stream start" ($r -match 'Streaming H.264') ($r.Trim() -replace '\s+', ' ')
        $null = Wait-Job $job -Timeout ($Seconds + 40)
        $cap = Receive-Job $job
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        $ss = Invoke-Cli $sp 'show stream'
        $se = Invoke-Cli $sp 'show encoder'
        $sf = Invoke-Cli $sp 'show framebuffer'
        $sd = Invoke-Cli $sp 'show ddr'
        [void](Invoke-Cli $sp 'stream stop')
        Say $ss.Trim()
        Say $se.Trim()
        $capDatagrams = 0; $capBytes = 0
        if ($cap) { $capDatagrams = $cap.Datagrams; $capBytes = $cap.Bytes }
        Say ("PC capture: {0} datagrams, {1} bytes, {2:N1} s, {3} datagrams not a multiple of 188 bytes" -f $capDatagrams, $capBytes, $(if ($cap) { $cap.Seconds } else { 0 }), $(if ($cap) { $cap.Odd } else { 0 }))
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
        Add-Result "$m board: pictures, drops, load" ($pics -ge ($Seconds * 25) -and $drop -eq 0 -and $udpDrop -eq 0 -and $errs -eq 0) `
            "pictures $pics, dropped pictures $drop, UDP drops $udpDrop, errors $errs, bit rate $kbps kb/s, TS mux load $mux %, handling+mux $busy %, frame buffer drops $fbDropShow"
        $gopOk = ($nIdr + $nP -eq $pics) -and ($(if ($Gop -eq 1) { $nP -eq 0 } else { $nP -gt 0 -and $nIdr -ge [Math]::Floor($pics / $Gop) -and $nIdr -le ([Math]::Ceiling($pics / $Gop) + 1) }))
        Add-Result "$m gop: IDR and P pictures" $gopOk "GOP $Gop, $nIdr IDR pictures ($avgIdr bytes each), $nP P pictures ($avgP bytes each), last picture $lastType"
        Say ("{0}: clocks per macroblock per engine (last picture {1}): {2} (budget 735)" -f $m, $lastType, ($perMb -join ' and '))
        $armErr = @([regex]::Matches($sd, 'errors (\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Where-Object { $_ -ne 0 })
        Add-Result "$m show ddr: arbiter errors" ($armErr.Count -eq 0 -and $sd -match 'Master 3') "all masters errors 0"
        if ($capDatagrams -gt 0) {
            Test-Capture $m $capFile $w $h 30.0
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
