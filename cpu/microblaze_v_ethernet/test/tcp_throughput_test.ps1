<#
-------------------------------------------------------------------------------
File: tcp_throughput_test.ps1
Purpose: lwIP TCP throughput test of the Ethernet demo (the firmware's iperf server, lwiperf, TCP port 5001) in both
  directions, board independent.
Overview:
  * iperf 2 from -Iperf, RTLNET_IPERF, PATH or <repo>/../tools/iperf, bound to the PC adapter's address (-B).
  * PC to board: iperf -c <board> -t <s>. Board to PC: the same with -R (the board sends on the client's connection).
    Both are reported in Mbit/s together with the link speed in effect (-LinkMbps, default the PC adapter speed; pass the
    board's link speed when a switch sits between them). Pass: the run produced a summary and the
    throughput is at least -MinMbps (default: half of the link speed up to 100 Mbit/s, so 5 / 50 / 50 for 10 / 100 /
    1000 Mb/s links; the measured values are the record, the gate only catches a stalled connection).
  * Final line: TCP_THROUGHPUT_TEST: PASS n/n or TCP_THROUGHPUT_TEST: FAIL f/n.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/tcp_throughput_test.ps1 -Port <COM port> -Nic <PC adapter> [-Seconds 10] [-LinkMbps <n>] [-MinMbps <n>] [-Iperf <iperf.exe>] [-OutDir <dir>] [-Csv <file>]
Revision: 11-14-2026
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [Parameter(Mandatory = $true)][string]$Nic,
    [string]$Board = '',
    [int]$Seconds = 10,
    [int]$LinkMbps = 0,
    [double]$MinMbps = -1,
    [string]$Iperf = '',
    [string]$OutDir = '',
    [string]$Csv = ''
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'eth_test_common.ps1')
Initialize-EthTest 'TCP_THROUGHPUT_TEST' $OutDir $Csv
$s = Initialize-EthSession $Port $Nic $Board
if ($s.Sp) { $s.Sp.Close() }
$ip = Resolve-EthIperf $Iperf
if (-not $ip) { Write-Output 'TCP_THROUGHPUT_TEST: FAIL no iperf 2 binary (use -Iperf, RTLNET_IPERF, PATH or <repo>/../tools/iperf)'; exit 1 }
$link = if ($LinkMbps -gt 0) { $LinkMbps } else { $s.Nic.Mbps }
if ($MinMbps -lt 0) { $MinMbps = [math]::Min(50.0, $link * 0.5) }
Write-Output "tcp_throughput_test: board $($s.Board) from $($s.Nic.Ip), link $link Mb/s, gate $MinMbps Mbit/s, iperf $ip"
foreach ($dir in @(@{ Name = 'PC to board'; Args = @() }, @{ Name = 'board to PC (-R)'; Args = @('-R') })) {
    $r = & $ip -c $s.Board -B $s.Nic.Ip -t $Seconds -f m @($dir.Args) 2>&1 | ForEach-Object { "$_" }
    Write-EthLog ($r -join "`n")
    $mb = Get-EthIperfMbps $r
    if ($null -ne $mb) {
        Add-EthRow "TCP $($dir.Name): throughput on a $link Mb/s link" ("{0:N1}" -f $mb) 'Mbit/s' ($mb -ge $MinMbps)
    } else {
        Add-EthRow "TCP $($dir.Name): iperf summary" 'none' '' $false
    }
}
Complete-EthTest
