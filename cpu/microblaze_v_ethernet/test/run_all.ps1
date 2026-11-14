<#
-------------------------------------------------------------------------------
File: run_all.ps1
Purpose: run the whole board-independent hardware test set of the Ethernet demo at one link speed and write a results
  table (CSV and text).
Overview:
  * Optionally sets the link with `speed <n>` first (-LinkMbps 10|100|1000; 1000 = speed auto, the power-up default),
    waits for the board (and, with -Direct, the PC adapter: board cabled straight to it) to report that speed, then runs, each as its own script with the same
    -Port, -Nic and -Board: console_test, ping_test, arp_test, dhcp_test, udp_echo_test, udp_iperf_test, tcp_echo_test,
    tcp_throughput_test. link_test (which changes the link speed itself) runs with -IncludeLink, last.
  * Each script appends its rows to <OutDir>/results_<speed>.csv (test, metric, value, unit, verdict); this script
    writes <OutDir>/results_<speed>.txt (the table) and prints one summary line per script and the final line
    ETH_SUITE: PASS n/n scripts (link <n> Mb/s) or ETH_SUITE: FAIL f/n scripts.
  * Transcripts: <OutDir>/<test>_transcript.txt per script.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/run_all.ps1 -Port <COM port> -Nic <PC adapter> [-LinkMbps 1000] [-IncludeLink] [-Direct] [-Iperf <iperf.exe>] [-OutDir <dir>]
Revision: 11-14-2026
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [Parameter(Mandatory = $true)][string]$Nic,
    [ValidateSet(10, 100, 1000)][int]$LinkMbps = 1000,
    [switch]$IncludeLink,
    [switch]$Direct,
    [string]$Iperf = '',
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'eth_test_common.ps1')
Initialize-EthTest 'ETH_SUITE' $OutDir ''
$out = $script:EthOutDir
$csv = Join-Path $out ("results_{0}.csv" -f $LinkMbps)
$txt = Join-Path $out ("results_{0}.txt" -f $LinkMbps)
Set-Content -LiteralPath $csv -Value '"test","metric","value","unit","verdict"' -Encoding ascii

# Set the link speed for the run and wait for both ends.
$sp = Open-EthConsole $Port
if (-not (Enter-EthPriv $sp)) { Write-Output "ETH_SUITE: FAIL no CLI prompt on $Port"; exit 1 }
$cmd = if ($LinkMbps -eq 1000) { 'speed auto' } else { "speed $LinkMbps" }
[void](Send-EthCli $sp 'configure terminal'); [void](Send-EthCli $sp 'interface eth0'); [void](Send-EthCli $sp $cmd); [void](Enter-EthPriv $sp)
$okB = Wait-EthBoardLink $sp $LinkMbps
$okN = $true
if ($Direct) { $okN = Wait-EthNicSpeed $Nic $LinkMbps }
$board = ''
if ($okB -and $okN) {
    Start-Sleep -Seconds 3
    $board = Get-EthBoardIp $sp
    if (-not $board -or $board -eq '0.0.0.0') { Start-Sleep -Seconds 8; $board = Get-EthBoardIp $sp }
}
$sp.Close()
Write-Output ("eth_suite: link {0} Mb/s: board {1}, PC adapter {2}, board address {3}" -f $LinkMbps, $okB, $okN, $board)
if (-not ($okB -and $okN) -or -not $board) { Write-Output "ETH_SUITE: FAIL link at $LinkMbps Mb/s not established"; exit 1 }

$scripts = @('console_test', 'ping_test', 'arp_test', 'dhcp_test', 'udp_echo_test', 'udp_iperf_test', 'tcp_echo_test', 'tcp_throughput_test')
$results = @()
foreach ($name in $scripts) {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot "$name.ps1"), '-Port', $Port, '-Nic', $Nic, '-OutDir', $out, '-Csv', $csv)
    if ($name -ne 'console_test') { $psArgs += @('-Board', $board) }
    if ($Iperf -and $name -match 'iperf|throughput') { $psArgs += @('-Iperf', $Iperf) }
    if ($name -match 'iperf|throughput') { $psArgs += @('-LinkMbps', $LinkMbps) }
    $o = & powershell.exe @psArgs
    $rc = $LASTEXITCODE
    $o | ForEach-Object { Write-Output "    $_" }
    $last = $o | Select-Object -Last 1
    Write-EthLog "=== $name (exit $rc)`n$($o -join "`n")"
    $results += [pscustomobject]@{ Script = $name; Exit = $rc; Last = "$last" }
    if ($name -eq 'console_test') {
        # The console test restarts the firmware: wait for the link and the address again.
        $sp = Open-EthConsole $Port
        [void](Enter-EthPriv $sp)
        [void](Wait-EthBoardLink $sp $LinkMbps 40)
        Start-Sleep -Seconds 5
        $nb = Get-EthBoardIp $sp
        if ($nb -and $nb -ne '0.0.0.0') { $board = $nb }
        $sp.Close()
    }
}
if ($IncludeLink) {
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'link_test.ps1') -Port $Port -Nic $Nic -Board $board -OutDir $out -Csv $csv -AutoMbps $LinkMbps @($(if ($Direct) { '-Direct' }))
    $rc = $LASTEXITCODE
    $o | ForEach-Object { Write-Output "    $_" }
    $results += [pscustomobject]@{ Script = 'link_test'; Exit = $rc; Last = "$($o | Select-Object -Last 1)" }
}

# Results table.
$rows = Import-Csv -LiteralPath $csv
$lines = @()
$lines += "RTLNet Ethernet demo hardware test results, link $LinkMbps Mb/s, board address $board, PC adapter $Nic"
$lines += ('{0,-20} {1,-62} {2,-24} {3,-8} {4}' -f 'test', 'metric', 'value', 'unit', 'verdict')
foreach ($r in $rows) { $lines += ('{0,-20} {1,-62} {2,-24} {3,-8} {4}' -f $r.test, $r.metric, $r.value, $r.unit, $r.verdict) }
$lines += ''
foreach ($r in $results) { $lines += ('{0,-22} exit {1}   {2}' -f $r.Script, $r.Exit, $r.Last) }
Set-Content -LiteralPath $txt -Value $lines -Encoding ascii
Write-Output "Results: $txt"
Write-Output "CSV: $csv"
$failed = @($results | Where-Object { $_.Exit -ne 0 }).Count
$total = $results.Count
if ($failed -eq 0) { Write-Output ("ETH_SUITE: PASS {0}/{0} scripts (link {1} Mb/s)" -f $total, $LinkMbps); exit 0 }
Write-Output ("ETH_SUITE: FAIL {0}/{1} scripts (link {2} Mb/s)" -f $failed, $total, $LinkMbps)
exit 1
