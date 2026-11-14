<#
-------------------------------------------------------------------------------
File: udp_iperf_test.ps1
Purpose: hardware UDP iperf throughput test of the Ethernet demo (the iperf 2 server in the FPGA fabric, UDP port 5001),
  board to PC and PC to board, board independent.
Overview:
  * iperf 2 from -Iperf, RTLNET_IPERF, PATH or <repo>/../tools/iperf (Resolve-RtlnetIperf), bound to the PC adapter's
    address (-B). A missing iperf makes the test FAIL (a check that cannot run is never passed).
  * PC to board: iperf -c <board> -u -b <rate> -t <s> -l 1470; the loss figure comes from the server report in the
    client output. Board to PC: the same with -R (the RTL server sends the datagrams). The offered rate is
    -Percent (default 90) percent of the link speed in effect (-LinkMbps, default the PC adapter speed: pass the board's
    link speed when a switch sits between them); pass = a report was received and the
    loss is at most 1 %.
  * Reports the achieved throughput (Mbit/s), loss, and the jitter where iperf prints it.
  * Final line: UDP_IPERF_TEST: PASS n/n or UDP_IPERF_TEST: FAIL f/n.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/udp_iperf_test.ps1 -Port <COM port> -Nic <PC adapter> [-Percent 90] [-Seconds 5] [-LinkMbps <n>] [-Iperf <iperf.exe>] [-OutDir <dir>] [-Csv <file>]
Revision: 11-14-2026
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [Parameter(Mandatory = $true)][string]$Nic,
    [string]$Board = '',
    [int]$Percent = 90,
    [int]$Seconds = 5,
    [int]$LinkMbps = 0,
    [switch]$NoSweep,
    [string]$Iperf = '',
    [string]$OutDir = '',
    [string]$Csv = ''
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'eth_test_common.ps1')
Initialize-EthTest 'UDP_IPERF_TEST' $OutDir $Csv
$s = Initialize-EthSession $Port $Nic $Board
if ($s.Sp) { $s.Sp.Close() }
$ip = Resolve-EthIperf $Iperf
if (-not $ip) { Write-Output 'UDP_IPERF_TEST: FAIL no iperf 2 binary (use -Iperf, RTLNET_IPERF, PATH or <repo>/../tools/iperf)'; exit 1 }
$link = if ($LinkMbps -gt 0) { $LinkMbps } else { $s.Nic.Mbps }
$rate = [int]($link * $Percent / 100)
Write-Output "udp_iperf_test: board $($s.Board) from $($s.Nic.Ip), link $link Mb/s, offered $rate Mb/s, iperf $ip"
foreach ($dir in @(@{ Name = 'PC to board'; Args = @() }, @{ Name = 'board to PC (-R)'; Args = @('-R') })) {
    $r = & $ip -c $s.Board -B $s.Nic.Ip -u -b "${rate}M" -t $Seconds -l 1470 @($dir.Args) 2>&1 | ForEach-Object { "$_" }
    Write-EthLog ($r -join "`n")
    $line = $r | Select-String -Pattern '([\d.]+)\s+Mbits/sec\s+([\d.]+)\s+ms\s+(\d+)/\s*(\d+)\s+\(([\d.e+-]+)%\)' | Select-Object -Last 1
    if ($line) {
        $m = $line.Matches[0]
        $mb = [double]$m.Groups[1].Value
        $lost = [double]$m.Groups[3].Value; $tot = [double]$m.Groups[4].Value
        $lossPct = if ($tot -gt 0) { [math]::Round(100.0 * $lost / $tot, 3) } else { 100.0 }
        Add-EthRow "UDP $($dir.Name): throughput at ${rate}M offered" ("{0:N1}" -f $mb) 'Mbit/s' ($lossPct -le 1.0 -and $mb -gt 0)
        Add-EthRow "UDP $($dir.Name): loss" ("{0}/{1} ({2} %)" -f $m.Groups[3].Value, $m.Groups[4].Value, $lossPct) '' ($lossPct -le 1.0)
        Add-EthRow "UDP $($dir.Name): jitter" $m.Groups[2].Value 'ms' $true
    } else {
        Add-EthRow "UDP $($dir.Name): server report" 'none' '' $false
    }
}
# Rate sweep: the highest offered rate (percent of the link) that loses no datagram, per direction.
if (-not $NoSweep) {
    foreach ($dir in @(@{ Name = 'PC to board'; Args = @() }, @{ Name = 'board to PC (-R)'; Args = @('-R') })) {
        $best = 0
        foreach ($pc in @(50, 70, 80, 90, 95, 98)) {
            $rt = [int]($link * $pc / 100)
            $r = & $ip -c $s.Board -B $s.Nic.Ip -u -b "${rt}M" -t 3 -l 1470 @($dir.Args) 2>&1 | ForEach-Object { "$_" }
            Write-EthLog ($r -join [Environment]::NewLine)
            $line = $r | Select-String -Pattern '([\d.]+)\s+Mbits/sec\s+([\d.]+)\s+ms\s+(\d+)/\s*(\d+)\s+\(([\d.e+-]+)%\)' | Select-Object -Last 1
            if ($line -and $line.Matches[0].Groups[3].Value -eq '0') { $best = $pc } else { break }
        }
        Add-EthRow "UDP $($dir.Name): highest zero-loss offered rate (sweep 50..98 %)" ("{0} % = {1}M" -f $best, [int]($link * $best / 100)) '' ($best -gt 0)
    }
}
Complete-EthTest
