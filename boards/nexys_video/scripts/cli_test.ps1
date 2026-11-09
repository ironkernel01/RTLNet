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
    storm-control; show classifier; show offload), tcp echo port change and restore in
    configuration mode, show running-config (TCP echo, storm control,
    classifier lines), led 2 on + LEDS register read-back, led 2 off, disable.
  * Either bitstream: CPU-only (network cores and classifier absent, lwIP
    not started) or network (lwIP running on the wrapper's address).
  * Writes the transcript to boards/nexys_video/build/cli_test_transcript.txt
    and prints it; the last line is "CLI_TEST: PASS <n>/<n>" or
    "CLI_TEST: FAIL <failed>/<n>"; exit code 0 only on PASS.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/cli_test.ps1 [-Port COM3] [-Baud 115200]
Revision: 10-22-2026
  * 10-22-2026: initial version.
  * 10-22-2026: CPU network path steps (BSP-based firmware).
-------------------------------------------------------------------------------
#>
param(
    [string]$Port = 'COM3',
    [int]$Baud = 115200,
    [int]$StepTimeoutMs = 5000,
    [string]$Transcript = ''
)
$ErrorActionPreference = 'Stop'
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Transcript) { $Transcript = Join-Path $Board 'build\cli_test_transcript.txt' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Transcript) | Out-Null

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

function Send-Step($sp, [string]$name, [string]$text, [string[]]$expect, [string]$promptExpect) {
    $sp.Write($text)
    $out = Read-UntilPrompt $sp $StepTimeoutMs
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
        'Board ID\s+: NXVD \(0x4E585644\)', 'Register map\s+: 10-22-2026', 'Build ID\s+: 0x[0-9a-f]{8} \(git [0-9a-f]{8}\), tree (clean|dirty)',
        'Firmware\s+: rtlnet-fw') 'rtlnet>'
    Send-Step $sp 'show system' "show system`r" @(
        'MMCM\s+: locked', 'CPU clock\s+: 100000000 Hz', 'Clock clk125\s*: 12[45]\.\d{3} MHz', 'Clock clk200\s*: (199|200)\.\d{3} MHz',
        'Clock axis_clk\s*: 62\.\d{3} MHz', 'Clock proto_clk\s*: (49|50)\.\d{3} MHz') 'rtlnet>'
    Send-Step $sp '? (exec)' '?' @('User exec commands:', 'show version\s+- ', 'enable\s+- ') 'rtlnet>'
    Send-Step $sp 'enable' "enable`r" @() 'rtlnet#'
    Send-Step $sp 'configure terminal' "configure terminal`r" @() 'rtlnet(config)#'
    Send-Step $sp '? (config)' '?' @('Global configuration commands:', 'interface \[IFNAME\]\s+- ', 'ip dhcp\s+- ', 'socket \[INDEX\]\s+- ') 'rtlnet(config)#'
    Send-Step $sp 'exit' "exit`r" @() 'rtlnet#'
    Send-Step $sp 'end' "end`r" @() 'rtlnet#'
    Send-Step $sp 'debug read 0x44a00000' "debug read 0x44a00000`r" @('0x44A00000 = 0x4E585644') 'rtlnet#'
    Send-Step $sp 'sh ver' "sh ver`r" @('Board ID\s+: NXVD', 'Register map\s+: 10-22-2026') 'rtlnet#'
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
$failed = @($script:results | Where-Object { -not $_.Ok }).Count
$total = $script:results.Count
if ($failed -eq 0 -and $total -gt 0) {
    Write-Output "CLI_TEST: PASS $total/$total"
    exit 0
}
Write-Output "CLI_TEST: FAIL $failed/$total"
exit 1
