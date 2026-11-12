<#
-------------------------------------------------------------------------------
File: hp_expiry_test.ps1
Purpose: board test of the High profile demo netlist (stage 1): the 30-minute license timer, its status and the forced IDR picture at its end.
Overview:
  * Takes the machine-wide board lock. Programs -Bit (default build/hp_demo/rtlnet_nexys_video.bit) over JTAG; program.tcl prints the host
    time at which the configuration finished ("configured at ... epoch ms").
  * Step 1 (right after configuration, before any stream): show encoder (High profile line, time left), encoder profile high (refused), show encoder
    again, with host timestamps, into <prefix>_pre.txt.
  * Step 2: stream_test.ps1 as a child process: 1080p30, static bars, constant QP, GOP 30, -Seconds s (default 1980 = 33 minutes) with a poll of
    show encoder every -PollSeconds s (every 5 s near the license end), -CcTolPct 0.01, -ForcedIdr 1; its transcript is <prefix>_stream.txt, the poll
    log <prefix>_1080p30_poll.txt.
  * Step 3: the poll log against the configuration time: the time left reaches 0 at 30 minutes after configuration within +-5 s; license ended
    afterwards; one forced IDR picture counted by the board.
  * Step 4 (after the capture): stream stop and start, and reload (firmware restart): the license stays ended. Then the board is programmed again
    with the same image: the license is back (time left near 30 minutes).
  * Output: boards/nexys_video/build/<prefix>_summary.txt; the last line is "HP_EXPIRY_TEST: PASS" or "HP_EXPIRY_TEST: FAIL <n>".
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/hp_expiry_test.ps1 [-Seconds 1980] [-PollSeconds 180] [-Prefix phase2e_hp_expiry]
Revision: 11-11-2026
  * 11-11-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string]$Bit = '',
    [int]$Seconds = 1980,
    [int]$PollSeconds = 0,
    [int]$PsnrStep = 15,
    [string]$Port = 'COM3',
    [string]$Prefix = 'phase2e_hp_expiry',
    [int]$LimitMinutes = 30,
    [int64]$CfgEpoch = 0,
    [string]$HostIp = '',
    [switch]$SkipStream
)
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo  = (Resolve-Path (Join-Path $Board '..\..')).Path
$Build = Join-Path $Board 'build'
if (-not $Bit) { $Bit = Join-Path $Build 'hp_demo\rtlnet_nexys_video.bit' }
. (Join-Path $Repo 'scripts\rtlnet_board_lock.ps1')
Enter-RtlnetBoardLock -Purpose 'high profile demo expiry test' -ExpectedMinutes ($Seconds / 60 + 60)
$Summary = Join-Path $Build "${Prefix}_summary.txt"
$script:lines = New-Object System.Collections.Generic.List[string]
$script:fail = 0
$PromptRe = '(rtlnet(\([a-z-]+\))?[>#])$'
function Say([string]$s) { Write-Host $s; $script:lines.Add($s) }
function Gate([string]$name, [bool]$ok, [string]$detail) {
    if (-not $ok) { $script:fail++ }
    Say ("  {0,-4} {1,-52} {2}" -f ($(if ($ok) { 'ok' } else { 'FAIL' })), $name, $detail)
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
        } else { Start-Sleep -Milliseconds 20 }
    }
    return $buf
}
function Open-Cli {
    $sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
    $sp.Handshake = [System.IO.Ports.Handshake]::None
    $sp.ReadTimeout = 200
    $sp.WriteTimeout = 2000
    $sp.Open()
    $sp.DiscardInBuffer()
    $sp.Write([string][char]3)
    $sp.Write("`r")
    $sync = Read-UntilPrompt $sp 20000
    if (($sync -replace "`r", '').TrimEnd(' ') -notmatch $PromptRe) { throw "no prompt on $Port" }
    if ($Matches[1] -ne 'rtlnet>') { $sp.Write([string][char]26); [void](Read-UntilPrompt $sp 5000); $sp.Write("disable`r"); [void](Read-UntilPrompt $sp 5000) }
    $sp.Write("enable`r"); [void](Read-UntilPrompt $sp 5000)
    return $sp
}
function Run-Cli($sp, [string]$line, [int]$timeoutMs = 8000) {
    $sp.Write($line + "`r")
    return ((Read-UntilPrompt $sp $timeoutMs) -replace "`r", '')
}
function Get-Field([string]$text, [string]$pattern) { if ($text -match $pattern) { return $Matches[1] } return '' }
function Epoch-Now { return [int64]([DateTimeOffset](Get-Date)).ToUnixTimeMilliseconds() }
function Program-Board {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'program.ps1') -Bit $Bit
    foreach ($l in $out) { Say "  | $l" }
    $m = [regex]::Match(($out -join "`n"), 'configured at .* \(epoch ms (\d+)')
    if (-not $m.Success) { throw 'program.ps1 did not report the configuration time (program failed?)' }
    return [int64]$m.Groups[1].Value
}
function Left-Seconds([string]$hpLine) {
    if ($hpLine -match 'time left (\d+) min (\d+) s') { return [int]$Matches[1] * 60 + [int]$Matches[2] }
    return -1
}

Say "HP_EXPIRY_TEST: image $Bit, limit $LimitMinutes min, capture $Seconds s, poll $PollSeconds s"
if ($CfgEpoch -gt 0) { $cfg = $CfgEpoch; Say 'resumed: configuration time given, programming and step 1 skipped' } else { $cfg = Program-Board }
Say ("configured at epoch ms {0} ({1:yyyy-MM-dd HH:mm:ss.fff})" -f $cfg, [DateTimeOffset]::FromUnixTimeMilliseconds($cfg).LocalDateTime)

# Step 1: right after configuration.
if ($CfgEpoch -le 0) {
$pre = New-Object System.Collections.Generic.List[string]
$sp = Open-Cli
$t1 = Epoch-Now
$e1 = Run-Cli $sp 'show encoder'
$hp1 = Get-Field $e1 'High profile\s+: ([^\r\n]*)'
$pre.Add(("{0} s after configuration | {1}" -f (($t1 - $cfg) / 1000.0), $hp1))
$pr = Run-Cli $sp 'encoder profile high'
$pre.Add("encoder profile high -> " + ($pr.Trim() -replace '\s+', ' '))
$t2 = Epoch-Now
$e2 = Run-Cli $sp 'show encoder'
$hp2 = Get-Field $e2 'High profile\s+: ([^\r\n]*)'
$pre.Add(("{0} s after configuration | {1}" -f (($t2 - $cfg) / 1000.0), $hp2))
$sp.Close()
Set-Content -LiteralPath (Join-Path $Build "${Prefix}_pre.txt") -Value $pre -Encoding ascii
foreach ($l in $pre) { Say "  pre: $l" }
$left1 = Left-Seconds $hp1
$elapsed1 = ($t1 - $cfg) / 1000.0
Gate 'right after configuration: present, licensed, time left near 30 min' ($hp1 -match 'present, licensed, time left' -and $left1 -gt 0 -and [Math]::Abs(($LimitMinutes * 60 - $left1) - $elapsed1) -le 5.0) `
    "time left $left1 s read $elapsed1 s after configuration (expected about $([int]($LimitMinutes * 60 - $elapsed1)) s)"
Gate 'time left does not rise (counts down)' ((Left-Seconds $hp2) -le $left1) "$left1 s then $(Left-Seconds $hp2) s"
Gate 'encoder profile high refused (hp_caps 0)' ($pr -match '% Profile high refused: the High profile module offers no tool yet \(hp_caps is 0\)') ($pr.Trim() -replace '\s+', ' ')
}

# Step 2: the stream across the expiry.
$st = Join-Path $Build "${Prefix}_stream.txt"
# the board takes about 30 s after configuration to get its DHCP lease; stream_test reads the effective address
$spw = Open-Cli
for ($w = 0; $w -lt 40; $w++) { $ipw = Run-Cli $spw 'show ip'; if ($ipw -match 'Effective IPv4\s+: 192\.168\.') { break }; Start-Sleep -Seconds 3 }
$spw.Close()
$args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'stream_test.ps1'), '-Mode', '1080p30', '-Seconds', "$Seconds", '-Gop', '30', '-Qp', '28',
           '-CcTolPct', '0.01', '-PollSeconds', "$PollSeconds", '-ForcedIdr', '1', '-SkipVlc', '-PsnrStep', "$PsnrStep", '-FilePrefix', $Prefix)
if ($HostIp) { $args2 += @('-HostIp', $HostIp) }
Say "stream_test: $($args2 -join ' ')"
if (-not $SkipStream) {
    $sw = Start-Process -FilePath 'powershell.exe' -ArgumentList $args2 -NoNewWindow -Wait -PassThru -RedirectStandardOutput $st -RedirectStandardError ($st + '.err')
    Say "stream_test exit code $($sw.ExitCode), transcript $st"
} else { Say "stream_test skipped (-SkipStream): using $st" }
$stLines = @(Get-Content -LiteralPath $st)
$stFail = @($stLines | Where-Object { $_ -match '^\s+FAIL ' })
foreach ($l in $stFail) { Say "  stream_test: $l" }

# Step 3: the expiry time. A CLI read blocks the firmware for 2 to 3 pictures (a polled capture has dropped pictures), so the capture is not polled:
# the forced IDR picture of the stream is the time stamp. Its PTS (seconds from the first access unit, plus the access units HEADTRIM cut off the
# start of the capture) is added to the host time of the stream start command.
$stText = $stLines -join "`n"
$mS = [regex]::Match($stText, 'STREAM_START_EPOCH_MS (\d+) (\d+)')
$mC = [regex]::Match($stText, 'HEADTRIM cut_packets=\d+ cut_access_units=(\d+)')
$tsText = (Get-Content -LiteralPath (Join-Path $Build "${Prefix}_1080p30_ts.txt")) -join "`n"
$mF = [regex]::Match($tsText, 'FORCED_IDR access_unit=(\d+) pts_s=([\d.]+) \(([^)]*)\)')
if ($mS.Success -and $mF.Success) {
    $tStart = ([double]$mS.Groups[1].Value + [double]$mS.Groups[2].Value) / 2.0
    $cutAu = $(if ($mC.Success) { [int]$mC.Groups[1].Value } else { 0 })
    $tForced = $tStart + ([double]$mF.Groups[2].Value + $cutAu / 30.0) * 1000.0
    $after = ($tForced - $cfg) / 1000.0
    Say ("forced IDR picture: access unit {0}, {1} s after the first access unit of the capture ({2} access units cut at the head), {3}; stream start command at {4:N1} s after configuration (+-{5:N2} s); forced IDR picture {6:N1} s after configuration (30 min = {7} s)" -f $mF.Groups[1].Value, $mF.Groups[2].Value, $cutAu, $mF.Groups[3].Value, (($tStart - $cfg) / 1000.0), (([double]$mS.Groups[2].Value - [double]$mS.Groups[1].Value) / 2000.0), $after, ($LimitMinutes * 60))
    Gate "forced IDR picture at $LimitMinutes min +-5 s from configuration" ([Math]::Abs($after - $LimitMinutes * 60) -le 5.0) ("{0:N2} s after configuration, {1:N2} s from {2} s" -f $after, ($after - $LimitMinutes * 60), ($LimitMinutes * 60))
} else { Gate "forced IDR picture at $LimitMinutes min +-5 s from configuration" $false 'no STREAM_START_EPOCH_MS or FORCED_IDR line in the stream_test transcript' }
$fsl = [string](@($stLines | Where-Object { $_ -match 'High profile\s+: ' }) | Select-Object -Last 1)
Gate 'board after the capture: license ended, 1 forced IDR picture' ($fsl -match 'license ended, time left 0 min 0 s, tools none \(hp_caps 0\), profile baseline, 1 forced IDR pictures') "$fsl"
$dr = @($stLines | Where-Object { $_ -match 'Pictures\s+: \d+ sent, (\d+) dropped' })
Gate '0 board-side dropped pictures' ($dr.Count -gt 0 -and $dr[0] -match ', 0 dropped') "$($dr -join ' ')"
$pollFile = Join-Path $Build "${Prefix}_1080p30_poll.txt"
if (Test-Path -LiteralPath $pollFile) { Say "poll log $pollFile (not used for the gates)" }

# Step 4: no restore by stream stop/start or reload.
$sp = Open-Cli
$ip = Run-Cli $sp 'show ip'
$hostIp = Get-Field $stLines[0] 'PC (\d+\.\d+\.\d+\.\d+)'
if (-not $hostIp) { $hostIp = Get-Field ($stLines -join "`n") 'PC (\d+\.\d+\.\d+\.\d+)' }
$a = Run-Cli $sp 'show encoder'
$hpA = Get-Field $a 'High profile\s+: ([^\r\n]*)'
[void](Run-Cli $sp 'stream stop')
$null = Run-Cli $sp "stream h264 $hostIp 5004"
Start-Sleep -Seconds 4
[void](Run-Cli $sp 'stream stop')
$b = Run-Cli $sp 'show encoder'
$hpB = Get-Field $b 'High profile\s+: ([^\r\n]*)'
Gate 'stream stop / start does not restore the license' ($hpA -match 'license ended' -and $hpB -match 'license ended') "before: $hpA | after: $hpB"
$sp.Write("reload`r")
Start-Sleep -Seconds 1
$sp.Close()
Start-Sleep -Seconds 12
$sp = Open-Cli
$c = Run-Cli $sp 'show encoder'
$hpC = Get-Field $c 'High profile\s+: ([^\r\n]*)'
$sp.Close()
Gate 'reload (firmware restart) does not restore the license' ($hpC -match 'license ended') $hpC

# Reprogramming restores it.
$cfg2 = Program-Board
$sp = Open-Cli
$tD = Epoch-Now
$d = Run-Cli $sp 'show encoder'
$hpD = Get-Field $d 'High profile\s+: ([^\r\n]*)'
$sp.Close()
Gate 'reprogramming the FPGA restores the license' ($hpD -match 'present, licensed, time left' -and (Left-Seconds $hpD) -gt ($LimitMinutes * 60 - 120)) "$hpD (read $(($tD - $cfg2) / 1000.0) s after configuration)"

Say $(if ($script:fail -eq 0) { 'HP_EXPIRY_TEST: PASS' } else { "HP_EXPIRY_TEST: FAIL $($script:fail)" })
Set-Content -LiteralPath $Summary -Value $script:lines -Encoding ascii
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
