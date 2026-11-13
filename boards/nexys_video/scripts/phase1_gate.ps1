<#
-------------------------------------------------------------------------------
File: phase1_gate.ps1
Purpose: board gate of Phase 1: the color bars run into the frame buffer with no
  firmware writes, the frame CRC-32 read back through the cache equals the C model at 720p30 and 1080p30, and the
  DDR3 arbiter reports no errors. Talks to the firmware CLI over the board USB-UART (115200 8N1) like cli_test.ps1.
Overview:
  * Takes the machine-wide board lock (rtlnet_board_lock.ps1).
  * The expected CRC-32 values come from the C model (cores/rtlnet_csi2_rx/testbench/csi2_bars_model.ps1, MODEL lines).
  * Steps (one result line each):
      a  sync, enable (no other write before step b)
      b  show camera: 720p30, source pattern, FRAME_COUNT rate 30.0 fps +/- 0.3 over 4 s of the PC clock
      c  framebuffer crc at 720p30 equals the C model
      d  camera mode 1080p30; show camera 1080p30; framebuffer crc twice, both equal the C model
      e  show ddr: arbiter errors 0 for master 0 and master 1, illegal-burst flag clear; show framebuffer: published
         above 0, dropped 0, bad 0, firmware holds none
      f  camera mode 720p30; camera rate 15 (rate from the PC clock against the printed period); camera rate 30;
         camera source pattern and auto; bad inputs rejected; framebuffer crc again equals the 720p30 model; show
         ddr and show framebuffer clean again. The board is left in the reset state (720p30, 30 fps, auto).
  * Writes the transcript to boards/nexys_video/build/phase1_gate_transcript.txt. The last line is
    "PHASE1_GATE: PASS <n>/<n>" or "PHASE1_GATE: FAIL <failed>/<n>"; exit code 0 only on PASS.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/phase1_gate.ps1 [-Port COM3]
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string]$Port = 'COM3',
    [int]$Baud = 115200,
    [int]$StepTimeoutMs = 8000,
    [double]$FpsTolerance = 0.3,
    [string]$Transcript = ''
)
$ErrorActionPreference = 'Stop'
$Repo  = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $Repo 'scripts\rtlnet_board_lock.ps1')
Enter-RtlnetBoardLock -Purpose 'phase1 gate' -ExpectedMinutes 30
if (-not $Transcript) { $Transcript = Join-Path $Board 'build\phase1_gate_transcript.txt' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Transcript) | Out-Null

# Expected CRCs from the C model.
$modelOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'cores\rtlnet_csi2_rx\testbench\csi2_bars_model.ps1')
$model = @{}
foreach ($l in $modelOut) {
    if ($l -match '^MODEL (\S+) width=(\d+) height=(\d+) bytes=(\d+) crc32=0x([0-9A-Fa-f]{8})$') {
        $model[$Matches[1]] = [pscustomobject]@{ Width = [int]$Matches[2]; Height = [int]$Matches[3]; Bytes = [int]$Matches[4]; Crc = $Matches[5].ToUpper() }
    }
}
if (-not $model.ContainsKey('720p30') -or -not $model.ContainsKey('1080p30')) {
    Write-Output "PHASE1_GATE: FAIL the C model printed no MODEL lines: $modelOut"
    exit 1
}
Write-Output ("C model: 720p30 crc32=0x{0}, 1080p30 crc32=0x{1}" -f $model['720p30'].Crc, $model['1080p30'].Crc)

$PromptRe = '(rtlnet(\([a-z-]+\))?[>#])$'
$script:log = New-Object System.Text.StringBuilder
$script:results = @()

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

# Send one command line, return the cleaned output (the reply text up to the next prompt) and the time the prompt came back.
function Invoke-Cli($sp, [string]$line, [int]$timeoutMs = 0) {
    if ($timeoutMs -le 0) { $timeoutMs = $StepTimeoutMs }
    $sp.Write($line + "`r")
    $out = Read-UntilPrompt $sp $timeoutMs
    $t = [System.Diagnostics.Stopwatch]::GetTimestamp()
    [void]$script:log.Append($out)
    $clean = $out -replace "`r", ''
    return [pscustomobject]@{ Text = $clean; Ticks = $t; Prompt = ($clean.TrimEnd(' ') -match $PromptRe) }
}

function Add-Result([string]$name, [bool]$ok, [string]$detail) {
    $script:results += [pscustomobject]@{ Step = $name; Ok = $ok; Detail = $detail }
    Write-Output ("  {0,-4} {1,-46} {2}" -f ($(if ($ok) { 'ok' } else { 'FAIL' })), $name, $detail)
}

# Frame count and period of a show camera reply.
function Get-Camera($r) {
    $o = [ordered]@{ Mode = ''; Source = ''; Active = ''; Period = 0; Fps = ''; Frames = -1; Ticks = $r.Ticks }
    if ($r.Text -match '(?m)Video mode\s+: (\S+) \(') { $o.Mode = $Matches[1] }
    if ($r.Text -match '(?m)Source setting\s+: (\S+)') { $o.Source = $Matches[1] }
    if ($r.Text -match '(?m)Active source\s+: (\S+)') { $o.Active = $Matches[1] }
    if ($r.Text -match '(?m)Frame period\s+: (\d+) ui_clk cycles \((\d+\.\d\d) fps\)') { $o.Period = [int64]$Matches[1]; $o.Fps = $Matches[2] }
    if ($r.Text -match '(?m)Frame count\s+: (\d+)') { $o.Frames = [int64]$Matches[1] }
    return [pscustomobject]$o
}

# Frame rate from two show camera readings against the PC clock.
function Get-Rate($a, $b) {
    $dt = ($b.Ticks - $a.Ticks) / [double][System.Diagnostics.Stopwatch]::Frequency
    if ($dt -le 0) { return 0.0 }
    return ($b.Frames - $a.Frames) / $dt
}

# CRC line of framebuffer crc.
function Get-Crc($r) {
    if ($r.Text -match 'Framebuffer CRC-32 : 0x([0-9A-F]{8}) \(frame (\d+), slot (\d+), (\d+)x(\d+), (\w+), (\d+) bytes\)') {
        return [pscustomobject]@{ Crc = $Matches[1]; Frame = [int]$Matches[2]; Slot = [int]$Matches[3]; W = [int]$Matches[4]; H = [int]$Matches[5]; Src = $Matches[6]; Bytes = [int]$Matches[7] }
    }
    return $null
}

function Test-Ddr($sp, [string]$tag) {
    $r = Invoke-Cli $sp 'show ddr'
    $m0 = $r.Text -match 'Master 0 \(CPU caches\):.* errors 0,'
    $m1 = $r.Text -match 'Master 1 \(video write DMA\): AW bursts [1-9]\d*, .* errors 0,'
    $fl = $r.Text -match 'illegal-burst flag clear'
    Add-Result "$tag show ddr: arbiter errors 0, both masters" ($m0 -and $m1 -and $fl) ("master0 clean $m0, master1 clean and active $m1, flag clear $fl")
}

function Test-Fb($sp, [string]$tag) {
    $r = Invoke-Cli $sp 'show framebuffer'
    $pub = $null
    $ok = $false
    if ($r.Text -match 'Published\s+: (\d+), dropped (\d+), bad (\d+)') { $pub = $Matches[1]; $ok = ([int]$Matches[1] -gt 0 -and [int]$Matches[2] -eq 0 -and [int]$Matches[3] -eq 0) }
    $hold = $r.Text -match 'Firmware holds\s+: none'
    $dma = $r.Text -match 'Write DMA\s+: frames ok [1-9]\d*, bad 0, dropped 0,'
    Add-Result "$tag show framebuffer: published, none dropped or bad" ($ok -and $hold -and $dma) ("published $pub, holds none $hold, write DMA clean $dma")
}

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.Handshake = [System.IO.Ports.Handshake]::None
$sp.ReadTimeout = 200
$sp.WriteTimeout = 2000
$sp.NewLine = "`r"
try {
    $sp.Open()
} catch {
    Write-Output "PHASE1_GATE: FAIL cannot open ${Port}: $($_.Exception.Message)"
    exit 1
}
try {
    # a: synchronize, enable. Nothing else is written before step b.
    $sp.DiscardInBuffer()
    $sp.Write([string][char]3)
    $sp.Write("`r")
    $sync = Read-UntilPrompt $sp $StepTimeoutMs
    [void]$script:log.Append($sync)
    $syncClean = ($sync -replace "`r", '').TrimEnd(' ')
    if ($syncClean -notmatch $PromptRe) {
        Write-Output "PHASE1_GATE: FAIL no prompt from the firmware on $Port within $StepTimeoutMs ms (received: '$sync')"
        exit 1
    }
    if ($Matches[1] -ne 'rtlnet>') {
        $sp.Write([string][char]26)
        [void]$script:log.Append((Read-UntilPrompt $sp $StepTimeoutMs))
        [void](Invoke-Cli $sp 'disable')
    }
    $r = Invoke-Cli $sp 'enable'
    Add-Result 'a  sync and enable' ($r.Text.TrimEnd(' ') -match 'rtlnet#$') 'privileged exec, no firmware writes yet'

    # b: reset state and frame rate from the PC clock.
    $c0 = Get-Camera (Invoke-Cli $sp 'show camera')
    Add-Result 'b1 show camera: reset state' ($c0.Mode -eq '720p30' -and $c0.Source -eq 'auto' -and $c0.Active -eq 'pattern' -and $c0.Period -eq 3000000) `
        ("mode $($c0.Mode), source setting $($c0.Source), active $($c0.Active), period $($c0.Period) ($($c0.Fps) fps), frame count $($c0.Frames)")
    Start-Sleep -Milliseconds 4000
    $c1 = Get-Camera (Invoke-Cli $sp 'show camera')
    $rate = Get-Rate $c0 $c1
    Add-Result 'b2 FRAME_COUNT rises 30 per second' ([math]::Abs($rate - 30.0) -le $FpsTolerance -and $c1.Active -eq 'pattern') ('{0:N3} fps over {1} frames (tolerance +/- {2})' -f $rate, ($c1.Frames - $c0.Frames), $FpsTolerance)

    # c: CRC at 720p30.
    $crc = Get-Crc (Invoke-Cli $sp 'framebuffer crc' 60000)
    $m = $model['720p30']
    Add-Result 'c  framebuffer crc 720p30 equals the C model' ($null -ne $crc -and $crc.Crc -eq $m.Crc -and $crc.W -eq $m.Width -and $crc.H -eq $m.Height -and $crc.Bytes -eq $m.Bytes -and $crc.Src -eq 'pattern') `
        $(if ($null -ne $crc) { "board 0x$($crc.Crc) ($($crc.W)x$($crc.H), frame $($crc.Frame), slot $($crc.Slot), $($crc.Bytes) bytes), model 0x$($m.Crc)" } else { 'no CRC line' })

    # d: 1080p30, two CRCs.
    $r = Invoke-Cli $sp 'camera mode 1080p30'
    Add-Result 'd1 camera mode 1080p30' ($r.Text -match 'Video mode 1080p30 \(1920x1080\)') 'accepted'
    Start-Sleep -Milliseconds 1000
    $c2 = Get-Camera (Invoke-Cli $sp 'show camera')
    Add-Result 'd2 show camera: 1080p30' ($c2.Mode -eq '1080p30' -and $c2.Active -eq 'pattern') "mode $($c2.Mode), active $($c2.Active), frame count $($c2.Frames)"
    $m = $model['1080p30']
    $crcA = Get-Crc (Invoke-Cli $sp 'framebuffer crc' 60000)
    $crcB = Get-Crc (Invoke-Cli $sp 'framebuffer crc' 60000)
    $okA = ($null -ne $crcA -and $crcA.Crc -eq $m.Crc -and $crcA.W -eq $m.Width -and $crcA.H -eq $m.Height -and $crcA.Bytes -eq $m.Bytes)
    $okB = ($null -ne $crcB -and $crcB.Crc -eq $m.Crc)
    Add-Result 'd3 framebuffer crc 1080p30 equals the C model' ($okA -and $okB) $(if ($null -ne $crcA -and $null -ne $crcB) { "board 0x$($crcA.Crc) then 0x$($crcB.Crc) (frames $($crcA.Frame), $($crcB.Frame)), model 0x$($m.Crc)" } else { 'no CRC line' })

    # e: arbiter and frame buffer health.
    Test-Ddr $sp 'e1'
    Test-Fb $sp 'e2'

    # f: back to 720p30, rate, source, rejections.
    $r = Invoke-Cli $sp 'camera mode 720p30'
    Add-Result 'f1 camera mode 720p30' ($r.Text -match 'Video mode 720p30 \(1280x720\)') 'accepted'
    $r = Invoke-Cli $sp 'camera rate 15'
    Add-Result 'f2 camera rate 15' ($r.Text -match 'Frame rate 15 fps \(6000000 ui_clk cycles per frame\)') 'accepted'
    Start-Sleep -Milliseconds 500
    $r0 = Get-Camera (Invoke-Cli $sp 'show camera')
    Start-Sleep -Milliseconds 2000
    $r1 = Get-Camera (Invoke-Cli $sp 'show camera')
    $rate15 = Get-Rate $r0 $r1
    $expect = 90000000.0 / [double]$r1.Period
    Add-Result 'f3 frame rate follows the printed period' ($r1.Period -eq 6000000 -and [math]::Abs($rate15 - $expect) -le 0.5) ('{0:N3} fps measured, {1:N3} fps from the period {2}' -f $rate15, $expect, $r1.Period)
    $r = Invoke-Cli $sp 'camera rate 30'
    Add-Result 'f4 camera rate 30' ($r.Text -match 'Frame rate 30 fps \(3000000 ui_clk cycles per frame\)') 'reset period restored'
    $r = Invoke-Cli $sp 'camera source pattern'
    $s1 = Get-Camera (Invoke-Cli $sp 'show camera')
    Add-Result 'f5 camera source pattern' ($r.Text -match 'Video source pattern' -and $s1.Source -eq 'pattern' -and $s1.Active -eq 'pattern') "setting $($s1.Source), active $($s1.Active)"
    $r = Invoke-Cli $sp 'camera source auto'
    $s2 = Get-Camera (Invoke-Cli $sp 'show camera')
    Add-Result 'f6 camera source auto' ($r.Text -match 'Video source auto' -and $s2.Source -eq 'auto' -and $s2.Active -eq 'pattern') "setting $($s2.Source), active $($s2.Active) (no camera: the pattern runs)"
    $b1 = Invoke-Cli $sp 'camera mode 4k'
    $b2 = Invoke-Cli $sp 'camera rate 0'
    $b3 = Invoke-Cli $sp 'camera rate 31'
    $b4 = Invoke-Cli $sp 'camera source radar'
    $badOk = ($b1.Text -match '% Invalid video mode') -and ($b2.Text -match '% Invalid frame rate') -and ($b3.Text -match '% Invalid frame rate') -and ($b4.Text -match '% Invalid video source')
    $s3 = Get-Camera (Invoke-Cli $sp 'show camera')
    Add-Result 'f7 bad inputs rejected, nothing changed' ($badOk -and $s3.Mode -eq '720p30' -and $s3.Period -eq 3000000 -and $s3.Source -eq 'auto') "mode $($s3.Mode), period $($s3.Period), source $($s3.Source)"
    Start-Sleep -Milliseconds 1000
    $m = $model['720p30']
    $crc2 = Get-Crc (Invoke-Cli $sp 'framebuffer crc' 60000)
    Add-Result 'f8 framebuffer crc 720p30 again' ($null -ne $crc2 -and $crc2.Crc -eq $m.Crc) $(if ($null -ne $crc2) { "board 0x$($crc2.Crc), model 0x$($m.Crc)" } else { 'no CRC line' })
    Test-Ddr $sp 'f9'
    Test-Fb $sp 'f10'
    [void](Invoke-Cli $sp 'disable')
} finally {
    $sp.Close()
}

$text = $script:log.ToString() -replace "`r`n", "`n" -replace "`r", ''
Set-Content -LiteralPath $Transcript -Value $text -Encoding ascii
$failed = @($script:results | Where-Object { -not $_.Ok }).Count
$total = $script:results.Count
if ($failed -eq 0 -and $total -gt 0) {
    Write-Output "PHASE1_GATE: PASS $total/$total"
    exit 0
}
Write-Output "PHASE1_GATE: FAIL $failed/$total"
exit 1
