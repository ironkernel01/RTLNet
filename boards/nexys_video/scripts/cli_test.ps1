<#
-------------------------------------------------------------------------------
File: cli_test.ps1
Purpose: hardware test of the RTLNet Nexys Video console: talk to the
  firmware CLI over the board USB-UART (System.IO.Ports.SerialPort, 115200
  8N1), run a fixed command sequence, check the answers and print a PASS/FAIL
  summary plus the transcript.
Overview:
  * Opens the port (default COM3); a busy or missing port is a FAIL with the
    exception text.
  * Synchronizes: Ctrl-C, CR, then waits for a prompt; from privileged or a
    configuration mode it returns to user exec (Ctrl-Z, disable).
  * Each step sends one line (or a bare '?', which the firmware answers
    without CR), reads until the next prompt (rtlnet...> or rtlnet...#) or a
    timeout, and checks regular expressions against that step's output and
    the prompt that ends it.
  * Sequence: show version, show system, ?, enable, configure terminal, ?,
    exit, end, debug read 0x44a00000, sh ver, then show interfaces (core
    absent message), the CPU network path (show cpu-path: AXI DMA found by
    the BSP driver; show tcp: lwIP state and TCP echo server; show
    storm-control; show classifier; show offload), the DDR3 path (show ddr: calibration done, arbiter
    identity, no illegal-burst flag; ddr test at the default size and at 64 MiB: all phases PASS and
    MB/s printed; a bad size rejected; the arbiter counters and error flag after the tests), tcp echo port change and restore in
    configuration mode, show running-config (TCP echo, storm control,
    classifier lines), led 2 on + LEDS register read-back, led 2 off, disable.
  * DDR3 image (banner "DDR3 image", or the Image line of show version): ddr test is refused there by design (the
    image runs from the tested region), so its three steps are skipped. Skipped steps are listed as "skip", are
    not counted as passed and appear in the last line: "CLI_TEST: PASS <n>/<n> (<k> skipped)".
  * Either bitstream: CPU-only (network cores and classifier absent, lwIP
    not started) or network (lwIP running on the wrapper's address).
  * Writes the transcript to boards/nexys_video/build/cli_test_transcript.txt
    and prints it; the last line is "CLI_TEST: PASS <n>/<n>" or
    "CLI_TEST: FAIL <failed>/<n>"; exit code 0 only on PASS.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/cli_test.ps1 [-Port COM3] [-Baud 115200]
Revision: 11-10-2026
  * 10-22-2026: initial version.
  * 10-22-2026: CPU network path steps (BSP-based firmware).
  * 11-09-2026: register map 11-09-2026; DDR3 steps (show ddr, ddr test, bad size).
  * 11-09-2026: takes the machine-wide board lock (rtlnet_board_lock.ps1) before touching the board.
  * 11-09-2026: arbiter with two masters (CPU caches, video write DMA); video steps (show camera, show framebuffer, camera
    mode, rate and source, framebuffer crc).
  * 11-09-2026: DDR3 image (banner "DDR3 image" or the show version Image line): the three ddr test steps are
    skipped, reported as skipped and not counted as passed.
  * 11-10-2026: Phase 2d: camera pattern (bad name, bad speed, all -7, box 24, bars), encoder bitrate, buffer and qprange (bad values, good values),
    the rate-control lines of show stream, show encoder history, back to constant QP.
  * 11-11-2026: High profile seam: the High profile line of show encoder, encoder profile (bad, high refused, baseline); tolerant of the default image and the High profile netlist image.
  * 11-10-2026: Phase 2c: encoder VERSION 0x11102C02, encoder gop (bad values, 1, 30) and the GOP lines of show stream and show encoder,
    the cache line of show ddr (32 KiB, 512-bit buses).
-------------------------------------------------------------------------------
#>
param(
    [string]$Port = 'COM3',
    [int]$Baud = 115200,
    [int]$StepTimeoutMs = 5000,
    [string]$Transcript = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\..\scripts\rtlnet_board_lock.ps1')
Enter-RtlnetBoardLock -Purpose 'cli test' -ExpectedMinutes 60
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Transcript) { $Transcript = Join-Path $Board 'build\cli_test_transcript.txt' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Transcript) | Out-Null

$PromptRe = '(rtlnet(\([a-z-]+\))?[>#])$'
$script:log = New-Object System.Text.StringBuilder
$script:results = @()
$script:skipped = @()

function Skip-Step([string]$name, [string]$why) {
    $script:skipped += [pscustomobject]@{ Step = $name; Why = $why }
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

function Send-Step($sp, [string]$name, [string]$text, [string[]]$expect, [string]$promptExpect, [int]$timeoutMs = 0) {
    if ($timeoutMs -le 0) { $timeoutMs = $StepTimeoutMs }
    $sp.Write($text)
    $out = Read-UntilPrompt $sp $timeoutMs
    [void]$script:log.Append($out)
    $clean = $out -replace "`r", ''
    $fails = @()
    foreach ($e in $expect) {
        if ($clean -notmatch $e) { $fails += "missing /$e/" }
    }
    $end = $clean.TrimEnd(' ')
    if ($end -notmatch $PromptRe) {
        $fails += 'no prompt (timeout)'
    } elseif ($promptExpect -and $Matches[1] -ne $promptExpect) {
        $fails += "prompt '$($Matches[1])', expected '$promptExpect'"
    }
    $ok = ($fails.Count -eq 0)
    $script:results += [pscustomobject]@{ Step = $name; Ok = $ok; Detail = ($fails -join '; ') }
}

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.Handshake = [System.IO.Ports.Handshake]::None
$sp.ReadTimeout = 200
$sp.WriteTimeout = 2000
$sp.NewLine = "`r"
try {
    $sp.Open()
} catch {
    Write-Output "CLI_TEST: FAIL cannot open ${Port}: $($_.Exception.Message)"
    exit 1
}
try {
    # Synchronize with the console and return to user exec mode.
    $sp.DiscardInBuffer()
    $sp.Write([string][char]3)
    $sp.Write("`r")
    $sync = Read-UntilPrompt $sp $StepTimeoutMs
    [void]$script:log.Append($sync)
    if (($sync -replace "`r", '').TrimEnd(' ') -notmatch $PromptRe) {
        Write-Output "CLI_TEST: FAIL no prompt from the firmware on $Port within $StepTimeoutMs ms (received: '$sync')"
        exit 1
    }
    if ($Matches[1] -ne 'rtlnet>') {
        $sp.Write([string][char]26)
        [void]$script:log.Append((Read-UntilPrompt $sp $StepTimeoutMs))
        $sp.Write("disable`r")
        [void]$script:log.Append((Read-UntilPrompt $sp $StepTimeoutMs))
    }

    Send-Step $sp 'show version' "show version`r" @(
        'Board ID\s+: NXVD \(0x4E585644\)', 'Register map\s+: 11-09-2026', 'Build ID\s+: 0x[0-9a-f]{8} \(git [0-9a-f]{8}\), tree (clean|dirty)',
        'Firmware\s+: rtlnet-fw') 'rtlnet>'
    Send-Step $sp 'show system' "show system`r" @(
        'MMCM\s+: locked', 'CPU clock\s+: 90000000 Hz', 'Clock clk125\s*: 12[45]\.\d{3} MHz', 'Clock clk200\s*: (199|200)\.\d{3} MHz',
        'Clock axis_clk\s*: 62\.\d{3} MHz', 'Clock proto_clk\s*: (49|50)\.\d{3} MHz') 'rtlnet>'
    Send-Step $sp '? (exec)' '?' @('User exec commands:', 'show version\s+- ', 'enable\s+- ') 'rtlnet>'
    Send-Step $sp 'enable' "enable`r" @() 'rtlnet#'
    Send-Step $sp 'configure terminal' "configure terminal`r" @() 'rtlnet(config)#'
    Send-Step $sp '? (config)' '?' @('Global configuration commands:', 'interface \[IFNAME\]\s+- ', 'ip dhcp\s+- ', 'socket \[INDEX\]\s+- ') 'rtlnet(config)#'
    Send-Step $sp 'exit' "exit`r" @() 'rtlnet#'
    Send-Step $sp 'end' "end`r" @() 'rtlnet#'
    Send-Step $sp 'debug read 0x44a00000' "debug read 0x44a00000`r" @('0x44A00000 = 0x4E585644') 'rtlnet#'
    Send-Step $sp 'sh ver' "sh ver`r" @('Board ID\s+: NXVD', 'Register map\s+: 11-09-2026') 'rtlnet#'
    Send-Step $sp 'show interfaces' "show interfaces`r" @('(% MAC not present in this build|eth0 is (up|down))') 'rtlnet#'
    Send-Step $sp 'show cpu-path' "show cpu-path`r" @(
        'AXI DMA\s+: 0x40400000, S2MM status 0x[0-9A-F]{8}, MM2S status 0x[0-9A-F]{8}', 'DMA receive\s+: frames \d+',
        'DMA transmit\s+: frames \d+', 'Classifier\s+: (present|not present in this build)') 'rtlnet#'
    Send-Step $sp 'show tcp' "show tcp`r" @(
        'lwIP\s+: (running|not started)', 'TCP echo\s+: enabled, port 7', 'Connections\s+: active \d+') 'rtlnet#'
    Send-Step $sp 'show storm-control' "show storm-control`r" @(
        'Storm control \(broadcast to the CPU\): enabled, 10 frames per 100 ms') 'rtlnet#'
    Send-Step $sp 'show classifier' "show classifier`r" @('mode pass-all', 'MAC 0\s+: dst ff:ff:ff:ff:ff:ff -> police 0') 'rtlnet#'
    Send-Step $sp 'show offload' "show offload`r" @('Checksum offload \(CPU path\)', 'Confirmed\s+: classifier (yes|no), offload TX (yes|no), offload RX (yes|no)',
        '(not present in this build|lwIP flags\s+: 0x[0-9A-F]{4})') 'rtlnet#'
    # The image name: the boot banner (when this run saw it) or the Image line of show version.
    $ddrImage = (($script:log.ToString() -replace "`r", '') -match '(DDR3 image|(?m)^\s*Image\s+: DDR3)')
    Send-Step $sp 'show ddr' "show ddr`r" @(
        'Calibration\s+: done', 'Arbiter\s+: ID "ARBT" 0x41524254, version 11-09-2026 at 0x44A04000',
        'Arbiter config\s+: 4 master\(s\), 16-byte beats, ID width 2, 8 outstanding, high-priority mask 0x02, narrow mask 0x01, wrap mask 0x01',
        'illegal-burst flag clear', 'Caches\s+: instruction 32 KiB, data 32 KiB write-back, 64-byte lines, 512-bit buses', 'Master 0 \(CPU caches\): AW bursts \d+',
        'Master 1 \(video write DMA\): AW bursts \d+, .* errors 0,', 'Master 2 \(encoder engine 0\): AW bursts \d+, .* errors 0,',
        'Master 3 \(encoder engine 1\): AW bursts \d+, .* errors 0,') 'rtlnet#'
    if ($ddrImage) {
        Skip-Step 'ddr test (bad size)' 'DDR3 image refuses ddr test'
        Skip-Step 'ddr test (default)' 'DDR3 image refuses ddr test'
        Skip-Step 'ddr test 64' 'DDR3 image refuses ddr test'
    } else {
        Send-Step $sp 'ddr test (bad size)' "ddr test 513`r" @('% Invalid size in MiB \(1\.\.512\) "513"') 'rtlnet#'
        Send-Step $sp 'ddr test (default)' "ddr test`r" @(
            'DDR3 test: 16 MiB at 0x80000000', 'Data bus\s+: PASS', 'Address bus\s+: PASS \(22 address offsets\)',
            'Random fill\s+: PASS \(16 MiB written and verified\)', 'Write\s+: \d+\.\d\d MB/s', 'Read\s+: \d+\.\d\d MB/s',
            'Master 0 \(CPU caches\):.* errors 0,', 'DDR3 test PASS') 'rtlnet#' 120000
        Send-Step $sp 'ddr test 64' "ddr test 64`r" @(
            'DDR3 test: 64 MiB at 0x80000000', 'Data bus\s+: PASS', 'Address bus\s+: PASS \(24 address offsets\)',
            'Random fill\s+: PASS \(64 MiB written and verified\)', 'Write\s+: \d+\.\d\d MB/s', 'Read\s+: \d+\.\d\d MB/s',
            'Master 0 \(CPU caches\):.* errors 0,', 'DDR3 test PASS') 'rtlnet#' 300000
    }
    Send-Step $sp 'show ddr (after)' "show ddr`r" @('Calibration\s+: done', 'illegal-burst flag clear',
        'Master 0 \(CPU caches\): AW bursts [1-9]\d*, AR bursts [1-9]\d*, W beats [1-9]\d*, R beats [1-9]\d*, errors 0,',
        'Master 1 \(video write DMA\): AW bursts \d+, .* errors 0,') 'rtlnet#'
    # Video (Phase 1): the commands and their output formats; no CRC value is asserted here (phase1_gate.ps1 compares it).
    Send-Step $sp 'show camera' "show camera`r" @(
        'ID "CSI2" 0x43534932', 'Video mode\s+: (720p30 \(1280x720\)|1080p30 \(1920x1080\))', 'Source setting\s+: (auto|camera|pattern)',
        'Active source\s+: (pattern|camera)', 'Frame period\s+: \d+ ui_clk cycles \(\d+\.\d\d fps\)', 'Frame count\s+: \d+',
        'Camera timeout\s+: \d+ frame periods', 'Status\s+: 0x[0-9A-F]{8} \(') 'rtlnet#'
    Send-Step $sp 'show framebuffer' "show framebuffer`r" @(
        'ID "FBUF" 0x46425546', 'ID "S2MM" 0x53324D4D', 'Slots\s+: 3 x 4096 KiB from DDR3 offset 0x[0-9A-F]{8} \(CPU 0x[0-9A-F]{8}\)',
        'Latest\s+: (slot \d, frame \d+, \d+x\d+, (pattern|camera), timestamp \d+|none published)', 'Firmware holds\s+: (none|slot \d)',
        'Published\s+: \d+, dropped \d+, bad \d+', 'Reference counts: slot 0 \d+, slot 1 \d+, slot 2 \d+',
        'Write DMA\s+: frames ok \d+, bad \d+, dropped \d+, bursts \d+, beats \d+, status 0x[0-9A-F]{8}') 'rtlnet#'
    Send-Step $sp 'camera mode 1080p30' "camera mode 1080p30`r" @('Video mode 1080p30 \(1920x1080\)') 'rtlnet#'
    Send-Step $sp 'show camera (1080p30)' "show camera`r" @('Video mode\s+: 1080p30 \(1920x1080\)') 'rtlnet#'
    Send-Step $sp 'camera mode 720p30' "camera mode 720p30`r" @('Video mode 720p30 \(1280x720\)') 'rtlnet#'
    Send-Step $sp 'camera mode (bad)' "camera mode 4k`r" @('% Invalid video mode \(720p30 or 1080p30\) "4k"') 'rtlnet#'
    Send-Step $sp 'camera rate 15' "camera rate 15`r" @('Frame rate 15 fps \(6000000 ui_clk cycles per frame\)') 'rtlnet#'
    Send-Step $sp 'show camera (15 fps)' "show camera`r" @('Frame period\s+: 6000000 ui_clk cycles \(15\.00 fps\)') 'rtlnet#'
    Send-Step $sp 'camera rate (bad)' "camera rate 31`r" @('% Invalid frame rate in fps \(1\.\.30\) "31"') 'rtlnet#'
    Send-Step $sp 'camera rate 30' "camera rate 30`r" @('Frame rate 30 fps \(3000000 ui_clk cycles per frame\)') 'rtlnet#'
    Send-Step $sp 'camera source (bad)' "camera source radar`r" @('% Invalid video source \(auto, camera or pattern\) "radar"') 'rtlnet#'
    Send-Step $sp 'camera source pattern' "camera source pattern`r" @('Video source pattern') 'rtlnet#'
    Send-Step $sp 'camera source auto' "camera source auto`r" @('Video source auto') 'rtlnet#'
    # Moving test patterns (Phase 2d).
    Send-Step $sp 'camera pattern (bad)' "camera pattern radar`r" @('% Invalid test pattern \(bars, scroll, box, noise or all\) "radar"') 'rtlnet#'
    Send-Step $sp 'camera pattern (bad speed)' "camera pattern scroll 33`r" @('% Invalid pattern speed \(-32\.\.32\) "33"') 'rtlnet#'
    Send-Step $sp 'camera pattern all -7' "camera pattern all -7`r" @('Test pattern all, speed -7, effective at the next frame') 'rtlnet#'
    Send-Step $sp 'show camera (pattern)' "show camera`r" @('Test pattern\s+: all, speed -7 px/frame, frame \d+ since the last restart') 'rtlnet#'
    Send-Step $sp 'camera pattern box 24' "camera pattern box 24`r" @('Test pattern box, speed 24, effective at the next frame') 'rtlnet#'
    Send-Step $sp 'camera pattern bars' "camera pattern bars`r" @('Test pattern bars, speed 4, effective at the next frame') 'rtlnet#'
    Send-Step $sp 'framebuffer crc' "framebuffer crc`r" @(
        'Framebuffer CRC-32 : 0x[0-9A-F]{8} \(frame \d+, slot \d, \d+x\d+, (pattern|camera), \d+ bytes\)') 'rtlnet#' 60000
    # H.264 stream (Phase 2b-3): command formats and refusals; the stream itself is checked by stream_test.ps1.
    Send-Step $sp 'encoder VERSION' "debug read 0x44a08004`r" @('0x44A08004 = 0x11102C02') 'rtlnet#'
    Send-Step $sp 'show encoder' "show encoder`r" @(
        'ID "H264" 0x48323634', 'GOP\s+: \d+ \(IDR every \d+ pictures, P pictures between\), last picture (IDR|P)', 'Build\s+: 2 engines, up to 120 x 68 macroblocks', 'QP\s+: \d+ configured, \d+ written; STATUS 0x[0-9A-F]{8}',
        'Engine 0\s+: \d+ macroblocks, picture \d+ cycles', 'Engine 1\s+: \d+ macroblocks, picture \d+ cycles') 'rtlnet#'
    # High profile seam (11-11-2026): tolerant of the default image (no seam or no netlist) and of a High profile netlist image (stage 1: present, hp_caps 0).
    Send-Step $sp 'show encoder (High profile line)' "show encoder`r" @(
        'High profile\s+: (not present \((this build has no High profile seam|the High profile netlist is not in this build)\)|present, (licensed|license ended), time left (unlimited|\d+ min \d+ s), tools none \(hp_caps 0\), profile baseline, \d+ forced IDR pictures)') 'rtlnet#'
    Send-Step $sp 'encoder profile (bad)' "encoder profile main`r" @('% Invalid profile \(baseline or high\) "main"') 'rtlnet#'
    Send-Step $sp 'encoder profile high (refused)' "encoder profile high`r" @(
        '% Profile high refused: (this build has no High profile seam|the High profile netlist is not in this build|the High profile module offers no tool yet \(hp_caps is 0\)|the High profile license has ended)') 'rtlnet#'
    Send-Step $sp 'encoder profile baseline' "encoder profile baseline`r" @('Profile baseline \(Constrained Baseline\), effective at the next picture') 'rtlnet#'
    Send-Step $sp 'encoder qp (bad)' "encoder qp 52`r" @('% Invalid QP \(0\.\.51\) "52"') 'rtlnet#'
    Send-Step $sp 'encoder qp 8 (floor)' "encoder qp 8`r" @('QP 8 set; the driver writes 12') 'rtlnet#'
    Send-Step $sp 'encoder qp 28' "encoder qp 28`r" @('QP 28, effective at the next picture') 'rtlnet#'
    Send-Step $sp 'encoder gop (bad 0)' "encoder gop 0`r" @('% Invalid GOP \(1\.\.255\) "0"') 'rtlnet#'
    Send-Step $sp 'encoder gop (bad 256)' "encoder gop 256`r" @('% Invalid GOP \(1\.\.255\) "256"') 'rtlnet#'
    Send-Step $sp 'encoder gop 1' "encoder gop 1`r" @('GOP 1 \(every picture is an IDR picture\), effective at the next picture') 'rtlnet#'
    Send-Step $sp 'show stream (gop 1)' "show stream`r" @('GOP\s+: 1 \(IDR every 1 pictures\); \d+ IDR pictures') 'rtlnet#'
    Send-Step $sp 'encoder gop 30' "encoder gop 30`r" @('GOP 30 \(an IDR picture every 30 pictures, P pictures between\), effective at the next picture') 'rtlnet#'
    Send-Step $sp 'show encoder (gop 30)' "show encoder`r" @('GOP\s+: 30 \(IDR every 30 pictures') 'rtlnet#'
    # Rate control (Phase 2d).
    Send-Step $sp 'encoder bitrate (bad)' "encoder bitrate 100001`r" @('% Invalid bit rate in kb/s \(0\.\.100000, 0 = constant QP\) "100001"') 'rtlnet#'
    Send-Step $sp 'encoder bitrate 2000' "encoder bitrate 2000`r" @('Constant bit rate 2000 kb/s, effective at the next picture') 'rtlnet#'
    Send-Step $sp 'encoder buffer (bad)' "encoder buffer 99`r" @('% Invalid buffer in ms \(100\.\.2000\) "99"') 'rtlnet#'
    Send-Step $sp 'encoder buffer 500' "encoder buffer 500`r" @('Rate control buffer 500 ms of the target rate') 'rtlnet#'
    Send-Step $sp 'encoder qprange (bad)' "encoder qprange 51 12`r" @('% Invalid QP range "51 12" \(12 <= min <= max <= 51\)') 'rtlnet#'
    Send-Step $sp 'encoder qprange 12 51' "encoder qprange 12 51`r" @('Rate control QP range 12\.\.51') 'rtlnet#'
    Send-Step $sp 'show stream (rate control)' "show stream`r" @(
        'Rate control\s+: constant bit rate, target 2000 kb/s, buffer 500 ms \(1000000 bits\), QP range 12\.\.51',
        'Measured rate\s+: \d+ kb/s over the last 1 s, \d+ kb/s over the last 10 s', 'Buffer fill\s+: \d+\.\d %', 'Picture QP\s+: last \d+; since clear min \d+, avg \d+\.\d\d, max \d+',
        'Buffer events\s+: overflow \d+ \(\d+ below QP max\), underflow \d+') 'rtlnet#'
    Send-Step $sp 'show encoder history 5' "show encoder history 5`r" @('Encoder history: \d+ of \d+ recorded seconds', 'Age \(s\)\s+Bits/s\s+QP avg\s+Fill %\s+Pictures') 'rtlnet#'
    Send-Step $sp 'show encoder history (bad)' "show encoder history 3601`r" @('% Invalid number of seconds \(1\.\.3600\) "3601"') 'rtlnet#'
    Send-Step $sp 'encoder bitrate 0' "encoder bitrate 0`r" @('Constant QP \d+ \(rate control off\), effective at the next picture') 'rtlnet#'
    Send-Step $sp 'show stream (constant QP)' "show stream`r" @('Rate control\s+: constant QP \d+ \(target 0\)', 'Buffer fill\s+: not used in constant QP mode') 'rtlnet#'
    Send-Step $sp 'stream h264 (bad address)' "stream h264 300.1.1.1 5004`r" @('% Invalid IPv4 address "300\.1\.1\.1"') 'rtlnet#'
    Send-Step $sp 'stream h264 (bad port)' "stream h264 192.168.68.1 0`r" @('% Invalid UDP port \(1\.\.65535\) "0"') 'rtlnet#'
    Send-Step $sp 'show stream (stopped)' "show stream`r" @(
        'State\s+: stopped', 'Pictures\s+: \d+ sent, \d+ dropped', 'GOP\s+: 30 \(IDR every 30 pictures\); \d+ IDR pictures \(\d+ bytes each on average\), \d+ P pictures', 'TS packets\s+: \d+ in \d+ datagrams',
        'CPU load\s+: TS mux \d+\.\d %', 'Errors\s+: \d+; frame buffer published \d+, dropped \d+') 'rtlnet#'
    Send-Step $sp 'stream stop (none)' "stream stop`r" @('No stream is running') 'rtlnet#'
    Send-Step $sp 'conf t (tcp)' "configure terminal`r" @() 'rtlnet(config)#'
    Send-Step $sp 'tcp echo port 2007' "tcp echo port 2007`r" @() 'rtlnet(config)#'
    Send-Step $sp 'end (tcp)' "end`r" @() 'rtlnet#'
    Send-Step $sp 'show tcp (port)' "show tcp`r" @('TCP echo\s+: enabled, port 2007') 'rtlnet#'
    Send-Step $sp 'conf t (restore)' "configure terminal`r" @() 'rtlnet(config)#'
    Send-Step $sp 'tcp echo port 7' "tcp echo port 7`r" @() 'rtlnet(config)#'
    Send-Step $sp 'end (restore)' "end`r" @() 'rtlnet#'
    Send-Step $sp 'show running-config' "show running-config`r" @(
        ' storm-control broadcast 10 100', 'tcp echo port 7', 'tcp echo enable', 'classifier mode pass-all', 'end') 'rtlnet#'
    Send-Step $sp 'led 2 on' "led 2 on`r" @('LED 2 on') 'rtlnet#'
    Send-Step $sp 'LEDS readback' "debug read 0x44a00014`r" @('0x44A00014 = 0x000000[0-9A-F][4567CDEF]') 'rtlnet#'
    Send-Step $sp 'led 2 off' "led 2 off`r" @('LED 2 off') 'rtlnet#'
    Send-Step $sp 'disable' "disable`r" @() 'rtlnet>'
} finally {
    $sp.Close()
}

$text = $script:log.ToString() -replace "`r`n", "`n" -replace "`r", ''
Set-Content -LiteralPath $Transcript -Value $text -Encoding ascii
Write-Output '----- transcript -----'
Write-Output $text
Write-Output '----- results -----'
foreach ($r in $script:results) {
    Write-Output ("  {0,-4} {1,-24} {2}" -f ($(if ($r.Ok) { 'ok' } else { 'FAIL' }), $r.Step, $r.Detail))
}
foreach ($s in $script:skipped) {
    Write-Output ("  {0,-4} {1,-24} {2}" -f 'skip', $s.Step, $s.Why)
}
$skipNote = $(if ($script:skipped.Count -gt 0) { " ($($script:skipped.Count) skipped: not counted as passed)" } else { '' })
$failed = @($script:results | Where-Object { -not $_.Ok }).Count
$total = $script:results.Count
if ($failed -eq 0 -and $total -gt 0) {
    Write-Output "CLI_TEST: PASS $total/$total$skipNote"
    exit 0
}
Write-Output "CLI_TEST: FAIL $failed/$total$skipNote"
exit 1
