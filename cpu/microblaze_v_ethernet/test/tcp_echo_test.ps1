<#
-------------------------------------------------------------------------------
File: tcp_echo_test.ps1
Purpose: lwIP TCP echo test of the Ethernet demo firmware (port 7), board independent.
Overview:
  * Runs eth_echo_test.py tcp, bound to the PC adapter's address: 4 concurrent connections, each sends messages of
    1 B .. 64 KiB (including the MSS boundaries 1459, 1460, 1461) and reads the same bytes back; every byte is compared.
    Then 8 connections with small messages.
  * Reports the aggregate echoed volume and time. Pass: every connection echoed every message byte-exact.
  * The board address comes from the console (`show ip`) unless -Board is given.
  * Final line: TCP_ECHO_TEST: PASS n/n or TCP_ECHO_TEST: FAIL f/n.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/tcp_echo_test.ps1 -Port <COM port> -Nic <PC adapter> [-Board <ip>] [-OutDir <dir>] [-Csv <file>]
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
Initialize-EthTest 'TCP_ECHO_TEST' $OutDir $Csv
$s = Initialize-EthSession $Port $Nic $Board
if ($s.Sp) { $s.Sp.Close() }
$py = Resolve-RtlnetPython
$script = Join-Path $PSScriptRoot 'eth_echo_test.py'
Write-Output "tcp_echo_test: board $($s.Board) from $($s.Nic.Ip)"
foreach ($run in @(@{ Name = '4 connections, 1 B .. 64 KiB'; Args = @('--conns', '4') }, @{ Name = '8 connections, small messages'; Args = @('--conns', '8', '--sizes', '1,7,64,100,1000,1460', '--rounds', '3') })) {
    $o = & $py -I $script tcp $s.Board --bind $s.Nic.Ip @($run.Args) 2>&1 | ForEach-Object { "$_" }
    Write-EthLog ($o -join "`n")
    $v = $o | Where-Object { $_ -match '^ETH_ECHO_TCP: ' } | Select-Object -Last 1
    $m = [regex]::Match(($o -join "`n"), 'tcp echo: (\d+) connections, (\d+) bytes echoed in ([\d.]+) s')
    Add-EthRow "TCP echo, $($run.Name): byte-exact" ("{0} bytes in {1} s" -f $m.Groups[2].Value, $m.Groups[3].Value) '' ($v -match 'PASS')
}
Complete-EthTest
