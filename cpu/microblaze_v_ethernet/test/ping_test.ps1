<#
-------------------------------------------------------------------------------
File: ping_test.ps1
Purpose: ICMP echo test of the Ethernet demo from the PC adapter: loss, round trip and a size sweep. Board independent.
Overview:
  * The board address is read from the console (`show ip`) unless -Board is given; pings leave from the adapter's IPv4
    address (ping -S), so only the named adapter carries them.
  * Size sweep: 0, 1, 64, 256, 512, 1024, 1400 and 1472 data bytes (the largest that fits the 1500-byte MTU without
    fragmentation), 10 echoes each, no loss allowed; then 100 echoes of 64 bytes.
  * Reports the minimum / average / maximum round trip of each run. Pass: no echo lost, every run produced a report.
  * Final line: PING_TEST: PASS n/n or PING_TEST: FAIL f/n.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/ping_test.ps1 -Port <COM port> -Nic <PC adapter> [-Board <ip>] [-OutDir <dir>] [-Csv <file>]
Revision: 11-14-2026
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [Parameter(Mandatory = $true)][string]$Nic,
    [string]$Board = '',
    [string]$OutDir = '',
    [string]$Csv = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'eth_test_common.ps1')
Initialize-EthTest 'PING_TEST' $OutDir $Csv
$s = Initialize-EthSession $Port $Nic $Board
if ($s.Sp) { $s.Sp.Close() }
$board = $s.Board
$src = $s.Nic.Ip
Write-Output "ping_test: board $board from $src ($($s.Nic.Mbps) Mb/s link)"
foreach ($len in @(0, 1, 64, 256, 512, 1024, 1400, 1472)) {
    $p = Invoke-EthPing $board $src 10 $len
    Add-EthRow "ping -l $len x10: lost" $p.Lost 'of 10' ($p.Lost -eq 0)
    Add-EthRow "ping -l $len x10: round trip min/avg/max" ("{0}/{1}/{2}" -f $p.MinMs, $p.AvgMs, $p.MaxMs) 'ms' ($p.AvgMs -ge 0)
}
$p = Invoke-EthPing $board $src 100 64
Add-EthRow 'ping -l 64 x100: lost' $p.Lost 'of 100' ($p.Lost -eq 0)
Add-EthRow 'ping -l 64 x100: round trip min/avg/max' ("{0}/{1}/{2}" -f $p.MinMs, $p.AvgMs, $p.MaxMs) 'ms' ($p.AvgMs -ge 0)
Complete-EthTest
