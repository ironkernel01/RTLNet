<#
-------------------------------------------------------------------------------
File: dhcp_test.ps1
Purpose: DHCP client test of the Ethernet demo, board independent: the board holds a lease from the LAN's DHCP server,
  uses it as its effective address, and renews it on request.
Overview:
  * `show dhcp`: state BOUND with a lease (address, mask, router, server, lease time); `show ip`: the effective
    address is the lease ("DHCP lease"); the lease address is on the PC adapter's subnet.
  * Renew from the console (configure terminal, ip dhcp, renew): the client sends a request (the counters
    `request` and `ack` rise), the state is BOUND again and the effective address is still the lease; a ping from the
    PC adapter then works.
  * Static fallback: the configuration keeps a static address (`show ip` Static IPv4) used only without a lease.
  * Final line: DHCP_TEST: PASS n/n or DHCP_TEST: FAIL f/n.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/dhcp_test.ps1 -Port <COM port> -Nic <PC adapter> [-OutDir <dir>] [-Csv <file>]
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
Initialize-EthTest 'DHCP_TEST' $OutDir $Csv

function Test-SameSubnet([string]$a, [string]$b, [string]$mask) {
    $ia = [System.Net.IPAddress]::Parse($a).GetAddressBytes(); $ib = [System.Net.IPAddress]::Parse($b).GetAddressBytes(); $im = [System.Net.IPAddress]::Parse($mask).GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) { if (($ia[$i] -band $im[$i]) -ne ($ib[$i] -band $im[$i])) { return $false } }
    return $true
}

$s = Initialize-EthSession $Port $Nic $Board
$sp = $s.Sp
try {
    $o = Send-EthCli $sp 'show dhcp'
    $bound = ($o -match 'state \w+, bound')
    Add-EthRow 'show dhcp: lease held' ($o -match 'DHCP client: state (\w+)') '' $bound
    $m = [regex]::Match($o, 'Lease\s+: (\d+\.\d+\.\d+\.\d+) mask (\d+\.\d+\.\d+\.\d+) router (\d+\.\d+\.\d+\.\d+) server (\d+\.\d+\.\d+\.\d+)')
    Add-EthRow 'show dhcp: lease address, mask, router, server' $m.Value '' $m.Success
    $lt = [regex]::Match($o, 'Lease time\s+: (\d+) s')
    Add-EthRow 'show dhcp: lease time' $lt.Groups[1].Value 's' ($lt.Success -and [int]$lt.Groups[1].Value -gt 0)
    $c0 = [regex]::Match($o, 'request (\d+), ack (\d+)')
    $leaseIp = $m.Groups[1].Value
    $mask = $m.Groups[2].Value
    $o = Send-EthCli $sp 'show ip'
    Add-EthRow 'show ip: effective address is the lease' ($o -match 'Effective IPv4\s+: (\d+\.\d+\.\d+\.\d+) .*\(DHCP lease\)') '' ($o -match "Effective IPv4\s+: $([regex]::Escape($leaseIp)) .*\(DHCP lease\)")
    Add-EthRow 'show ip: static fallback address kept' ($o -match 'Static IPv4\s+: (\d+\.\d+\.\d+\.\d+)') '' ($o -match 'Static IPv4\s+: \d+\.\d+\.\d+\.\d+')
    if ($leaseIp -and $mask) {
        Add-EthRow 'lease address on the PC adapter subnet' ("{0} / {1}" -f $leaseIp, $s.Nic.Ip) '' (Test-SameSubnet $leaseIp $s.Nic.Ip $mask)
    }
    [void](Send-EthCli $sp 'configure terminal')
    [void](Send-EthCli $sp 'ip dhcp')
    [void](Send-EthCli $sp 'renew')
    [void](Enter-EthPriv $sp)
    Start-Sleep -Seconds 4
    $o = Send-EthCli $sp 'show dhcp'
    Add-EthRow 'after renew: lease held' ($o -match 'DHCP client: state (\w+)') '' ($o -match 'state \w+, bound')
    $c1 = [regex]::Match($o, 'request (\d+), ack (\d+)')
    $okc = $c0.Success -and $c1.Success -and ([int]$c1.Groups[1].Value -gt [int]$c0.Groups[1].Value) -and ([int]$c1.Groups[2].Value -gt [int]$c0.Groups[2].Value)
    Add-EthRow 'after renew: request and ack counters rose' ("{0},{1} -> {2},{3}" -f $c0.Groups[1].Value, $c0.Groups[2].Value, $c1.Groups[1].Value, $c1.Groups[2].Value) '' $okc
    $ip = Get-EthBoardIp $sp
    Add-EthRow 'after renew: effective address' $ip '' ($ip -eq $leaseIp)
    $p = Invoke-EthPing $ip $s.Nic.Ip 10 64
    Add-EthRow 'ping after renew: lost' $p.Lost 'of 10' ($p.Lost -eq 0)
} finally {
    if ($sp -and $sp.IsOpen) { $sp.Close() }
}
Complete-EthTest
