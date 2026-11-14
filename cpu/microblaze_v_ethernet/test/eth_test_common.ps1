<#
-------------------------------------------------------------------------------
File: eth_test_common.ps1
Purpose: shared helpers of the board-independent hardware tests of the Ethernet CPU (cpu/microblaze_v_ethernet/test):
  the console (CLI on the USB-UART), the PC adapter, ping, iperf lookup, result rows and the final verdict line.
Overview:
  * Dot-sourced by every test script (. (Join-Path $PSScriptRoot 'eth_test_common.ps1')). Nothing here names a board:
    the console port (-Port), the PC adapter (-Nic) and the board's IPv4 address (read from the console with `show ip`,
    it is a DHCP lease and changes between sessions) are arguments or discovered.
  * Console: Open-EthConsole / Send-EthCli drive the hierarchical CLI (prompt rtlnet>, rtlnet#, rtlnet(config-if)#...).
  * PC adapter: Get-EthNic returns its IPv4 address and link speed; tests bind sockets and iperf to that address, so
    the traffic leaves on the named adapter only (a Wi-Fi adapter on the same subnet is never used).
  * Results: Add-EthRow records one measurement or check (also appended to the CSV given by -Csv); Complete-EthTest
    prints the table, writes the transcript file and prints the final line "<NAME>: PASS n/n" or "<NAME>: FAIL f/n".
  * PowerShell 5.1, ASCII only.
Revision: 11-14-2026
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
# Repository tools, dot-sourced at file level so that the caller's scope has them: tool discovery and the machine-wide board lock.
$script:EthRepo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $script:EthRepo 'scripts\rtlnet_tools.ps1')
. (Join-Path $script:EthRepo 'scripts\rtlnet_board_lock.ps1')
$script:EthLog = New-Object System.Text.StringBuilder
$script:EthRows = @()
$script:EthPromptRe = '(rtlnet(\([a-z-]+\))?[>#])\s*$'
$script:EthCsv = ''
$script:EthName = 'ETH_TEST'
$script:EthOutDir = ''

function Initialize-EthTest([string]$Name, [string]$OutDir, [string]$Csv) {
    $script:EthName = $Name
    if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $script:EthOutDir = (Resolve-Path -LiteralPath $OutDir).Path
    $script:EthCsv = $Csv
    $script:EthRows = @()
    [void]$script:EthLog.Clear()
    Enter-RtlnetBoardLock -Purpose "ethernet test $Name" -ExpectedMinutes 60
}

function Write-EthLog([string]$text) { [void]$script:EthLog.Append($text + "`n") }

function Add-EthRow([string]$Metric, $Value, [string]$Unit, [bool]$Ok) {
    $row = [pscustomobject]@{ Test = $script:EthName; Metric = $Metric; Value = "$Value"; Unit = $Unit; Verdict = $(if ($Ok) { 'PASS' } else { 'FAIL' }) }
    $script:EthRows += $row
    Write-Output ("  {0,-4} {1,-52} {2} {3}" -f $row.Verdict, $Metric, $Value, $Unit)
    if ($script:EthCsv) {
        $line = '"{0}","{1}","{2}","{3}","{4}"' -f $row.Test, ($Metric -replace '"', "'"), ($row.Value -replace '"', "'"), $Unit, $row.Verdict
        Add-Content -LiteralPath $script:EthCsv -Value $line -Encoding ascii
    }
}

function Complete-EthTest {
    $text = $script:EthLog.ToString() -replace "`r`n", "`n" -replace "`r", ''
    $tp = Join-Path $script:EthOutDir ("{0}_transcript.txt" -f $script:EthName.ToLower())
    Set-Content -LiteralPath $tp -Value $text -Encoding ascii
    $failed = @($script:EthRows | Where-Object { $_.Verdict -ne 'PASS' }).Count
    $total = $script:EthRows.Count
    Write-Output "Transcript: $tp"
    if ($failed -eq 0 -and $total -gt 0) {
        Write-Output ("{0}: PASS {1}/{1}" -f $script:EthName, $total)
        exit 0
    }
    Write-Output ("{0}: FAIL {1}/{2}" -f $script:EthName, $failed, $total)
    exit 1
}

function Open-EthConsole([string]$Port) {
    $sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
    $sp.Handshake = [System.IO.Ports.Handshake]::None
    $sp.ReadTimeout = 200
    $sp.WriteTimeout = 2000
    $sp.Open()
    $sp.DiscardInBuffer()
    $sp.Write([string][char]3)
    return $sp
}

function Send-EthCli($sp, [string]$cmd, [int]$timeoutMs = 6000) {
    $sp.Write($cmd + "`r")
    $buf = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $c = $sp.ReadExisting()
        if ($c.Length -gt 0) {
            $buf += $c
            if (($buf -replace "`r", '') -match $script:EthPromptRe) {
                Start-Sleep -Milliseconds 100
                $more = $sp.ReadExisting()
                if ($more.Length -eq 0) { break }
                $buf += $more
            }
        } else { Start-Sleep -Milliseconds 20 }
    }
    $clean = $buf -replace "`r", ''
    Write-EthLog $clean
    return $clean
}

# Leave any configuration mode and enter privileged exec; returns $true when the prompt is rtlnet#.
function Enter-EthPriv($sp) {
    [void](Send-EthCli $sp '')
    for ($i = 0; $i -lt 3; $i++) {
        $o = Send-EthCli $sp 'end'
        if ($o -match 'rtlnet#\s*$') { return $true }
        $o = Send-EthCli $sp 'enable'
        if ($o -match 'rtlnet#\s*$') { return $true }
        [void](Send-EthCli $sp 'exit')
    }
    return $false
}

function Get-EthBoardIp($sp) {
    $o = Send-EthCli $sp 'show ip'
    if ($o -match 'Effective IPv4\s+: (\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
    return ''
}

function Get-EthBoardMac($sp) {
    $o = Send-EthCli $sp 'show ip'
    if ($o -match 'Node MAC\s+: ([0-9a-fA-F:]{17})') { return ($Matches[1].ToLower() -replace ':', '-') }
    return ''
}

# Link line of "show interfaces": returns the speed in Mb/s when eth0 is up, else 0.
function Get-EthBoardLink($sp) {
    $o = Send-EthCli $sp 'show interfaces'
    if ($o -match 'eth0 is up, (\d+) Mb/s full duplex') { return [int]$Matches[1] }
    return 0
}

function Wait-EthBoardLink($sp, [int]$mbps, [int]$timeoutS = 25) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $l = 0
    while ($sw.Elapsed.TotalSeconds -lt $timeoutS) {
        $l = Get-EthBoardLink $sp
        if ($l -eq $mbps) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

# The PC adapter: IPv4 address, link speed in Mb/s, status.
function Get-EthNic([string]$Nic) {
    $a = Get-NetAdapter -Name $Nic -ErrorAction SilentlyContinue
    if (-not $a) { return $null }
    $ip = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    return [pscustomobject]@{ Name = $Nic; Status = [string]$a.Status; Ip = $(if ($ip) { $ip.IPAddress } else { '' }); Mbps = [int]($a.Speed / 1000000) }
}

function Wait-EthNicSpeed([string]$Nic, [int]$mbps, [int]$timeoutS = 25) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutS) {
        $n = Get-EthNic $Nic
        if ($n -and $n.Status -eq 'Up' -and $n.Mbps -eq $mbps) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

# Read the board address and PC adapter; stops the test (FAIL line) when either is unusable. Returns @{ Sp; Board; Nic }.
function Initialize-EthSession([string]$Port, [string]$Nic, [string]$Board) {
    $nicInfo = Get-EthNic $Nic
    if (-not $nicInfo -or $nicInfo.Status -ne 'Up' -or -not $nicInfo.Ip) {
        Write-Output ("{0}: FAIL PC adapter '{1}' is not usable (status {2})" -f $script:EthName, $Nic, $(if ($nicInfo) { $nicInfo.Status } else { 'not found' }))
        exit 1
    }
    $sp = $null
    if ($Port) {
        try { $sp = Open-EthConsole $Port } catch {
            Write-Output ("{0}: FAIL cannot open {1}: {2}" -f $script:EthName, $Port, $_.Exception.Message)
            exit 1
        }
        if (-not (Enter-EthPriv $sp)) { Write-Output ("{0}: FAIL no CLI prompt on {1}" -f $script:EthName, $Port); exit 1 }
        if (-not $Board) { $Board = Get-EthBoardIp $sp }
    }
    if (-not $Board -or $Board -eq '0.0.0.0') { Write-Output ("{0}: FAIL the board has no IPv4 address (show ip); pass -Board" -f $script:EthName); exit 1 }
    return [pscustomobject]@{ Sp = $sp; Board = $Board; Nic = $nicInfo }
}

# ping from the adapter's address; returns @{ Sent; Lost; MinMs; AvgMs; MaxMs }.
function Invoke-EthPing([string]$Board, [string]$SrcIp, [int]$Count, [int]$Size) {
    $p = & ping -S $SrcIp -n $Count -l $Size -w 1000 $Board
    Write-EthLog (($p -join "`n"))
    $lost = -1; $sent = $Count; $min = -1; $avg = -1; $max = -1
    $m = $p | Select-String -Pattern 'Sent = (\d+), Received = (\d+), Lost = (\d+)'
    if ($m) { $sent = [int]$m.Matches[0].Groups[1].Value; $lost = [int]$m.Matches[0].Groups[3].Value }
    $r = $p | Select-String -Pattern 'Minimum = (\d+)ms, Maximum = (\d+)ms, Average = (\d+)ms'
    if ($r) { $min = [int]$r.Matches[0].Groups[1].Value; $max = [int]$r.Matches[0].Groups[2].Value; $avg = [int]$r.Matches[0].Groups[3].Value }
    return [pscustomobject]@{ Sent = $sent; Lost = $lost; MinMs = $min; AvgMs = $avg; MaxMs = $max }
}

function Resolve-EthIperf([string]$Given) {
    if ($Given -and (Test-Path -LiteralPath $Given)) { return $Given }
    $x = Resolve-RtlnetIperf
    if ($x) { return $x }
    return $null
}

# Last "<n> <unit>bits/sec" figure of an iperf summary, in Mbit/s ($null when none).
function Get-EthIperfMbps([string[]]$lines) {
    $m = $lines | Select-String -Pattern '([\d.]+)\s+([KMG]?)bits/sec' | Select-Object -Last 1
    if (-not $m) { return $null }
    $v = [double]$m.Matches[0].Groups[1].Value
    switch ($m.Matches[0].Groups[2].Value) { 'G' { $v *= 1000.0 } 'K' { $v /= 1000.0 } '' { $v /= 1000000.0 } }
    return $v
}
