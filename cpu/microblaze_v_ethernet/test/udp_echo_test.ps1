<#
-------------------------------------------------------------------------------
File: udp_echo_test.ps1
Purpose: hardware UDP echo test of the Ethernet demo (rtlnet_udp_echo in the FPGA fabric, port 7), board independent.
Overview:
  * Runs eth_echo_test.py udp, bound to the PC adapter's address: 400 datagrams of sizes 0 to 1472 bytes, every reply
    compared byte for byte; no datagram may be lost, late or corrupt. Reports the round-trip time (min, mean, median,
    99th percentile, max).
  * Then 2000 datagrams of 64 bytes for the latency distribution and the loss figure.
  * The board address comes from the console (`show ip`) unless -Board is given.
  * Final line: UDP_ECHO_TEST: PASS n/n or UDP_ECHO_TEST: FAIL f/n.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/udp_echo_test.ps1 -Port <COM port> -Nic <PC adapter> [-Board <ip>] [-OutDir <dir>] [-Csv <file>]
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
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'eth_test_common.ps1')
Initialize-EthTest 'UDP_ECHO_TEST' $OutDir $Csv
$s = Initialize-EthSession $Port $Nic $Board
if ($s.Sp) { $s.Sp.Close() }
$py = Resolve-RtlnetPython
$script = Join-Path $PSScriptRoot 'eth_echo_test.py'
Write-Output "udp_echo_test: board $($s.Board) from $($s.Nic.Ip)"
$o = & $py -I $script udp $s.Board --bind $s.Nic.Ip -n 400 2>&1 | ForEach-Object { "$_" }
Write-EthLog ($o -join "`n")
$v = $o | Where-Object { $_ -match '^ETH_ECHO_UDP: ' } | Select-Object -Last 1
$m = [regex]::Match(($o -join "`n"), 'sent (\d+), echoed (\d+), lost (\d+) \(([\d.]+) %\), late (\d+), mismatched (\d+)')
Add-EthRow 'sizes 0..1472, 400 datagrams: echoed byte-exact' ("{0}/{1}" -f $m.Groups[2].Value, $m.Groups[1].Value) '' ($v -match 'PASS')
Add-EthRow 'sizes 0..1472: lost / late / mismatched' ("{0}/{1}/{2}" -f $m.Groups[3].Value, $m.Groups[5].Value, $m.Groups[6].Value) '' ($m.Success -and $m.Groups[3].Value -eq '0' -and $m.Groups[6].Value -eq '0')
$r = [regex]::Match(($o -join "`n"), 'round trip ms: min ([\d.]+) mean ([\d.]+) median ([\d.]+) p99 ([\d.]+) max ([\d.]+)')
if ($r.Success) { Add-EthRow 'round trip min/mean/median/p99/max' ("{0}/{1}/{2}/{3}/{4}" -f $r.Groups[1].Value, $r.Groups[2].Value, $r.Groups[3].Value, $r.Groups[4].Value, $r.Groups[5].Value) 'ms' $true }
$o = & $py -I $script udp $s.Board --bind $s.Nic.Ip -n 2000 --sizes 64 2>&1 | ForEach-Object { "$_" }
Write-EthLog ($o -join "`n")
$v = $o | Where-Object { $_ -match '^ETH_ECHO_UDP: ' } | Select-Object -Last 1
$m = [regex]::Match(($o -join "`n"), 'sent (\d+), echoed (\d+), lost (\d+) \(([\d.]+) %\)')
Add-EthRow '64-byte datagrams x2000: lost' ("{0} ({1} %)" -f $m.Groups[3].Value, $m.Groups[4].Value) '' ($v -match 'PASS')
$r = [regex]::Match(($o -join "`n"), 'round trip ms: min ([\d.]+) mean ([\d.]+) median ([\d.]+) p99 ([\d.]+) max ([\d.]+)')
if ($r.Success) { Add-EthRow '64-byte round trip min/mean/median/p99/max' ("{0}/{1}/{2}/{3}/{4}" -f $r.Groups[1].Value, $r.Groups[2].Value, $r.Groups[3].Value, $r.Groups[4].Value, $r.Groups[5].Value) 'ms' $true }
Complete-EthTest
