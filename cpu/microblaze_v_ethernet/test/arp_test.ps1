<#
-------------------------------------------------------------------------------
File: arp_test.ps1
Purpose: ARP test of the Ethernet demo, board independent: the board answers ARP requests (hardware ARP responder) and
  the PC learns its MAC.
Overview:
  * The board's MAC and address come from the console (`show ip`). The PC's ARP entry of the board is deleted when the
    shell is elevated (arp -d needs it; without elevation the entry is left and the check runs on the existing one),
    the PC pings the board once from the named adapter (the ping triggers an ARP request when no entry exists), and the
    ARP table of the PC (arp -a) must list the board's address with the board's MAC.
  * The ARP responder counters of the board (`show arp`: requests for us, replies sent) do not decrease, and with a
    deleted entry they increase by at least one reply.
  * Final line: ARP_TEST: PASS n/n or ARP_TEST: FAIL f/n.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/arp_test.ps1 -Port <COM port> -Nic <PC adapter> [-OutDir <dir>] [-Csv <file>]
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
Initialize-EthTest 'ARP_TEST' $OutDir $Csv
$s = Initialize-EthSession $Port $Nic $Board
$sp = $s.Sp
try {
    $board = $s.Board
    $mac = Get-EthBoardMac $sp
    Add-EthRow 'board MAC from show ip' $mac '' ($mac -match '^[0-9a-f]{2}(-[0-9a-f]{2}){5}$')
    $o = Send-EthCli $sp 'show arp'
    $before = 0; $repBefore = 0
    if ($o -match 'requests for us (\d+), replies sent (\d+)') { $before = [int]$Matches[1]; $repBefore = [int]$Matches[2] }
    $deleted = $false
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        & arp -d $board 2>&1 | Out-Null
        $deleted = $true
    }
    Write-Output ("arp_test: PC ARP entry deleted: {0}" -f $deleted)
    $p = Invoke-EthPing $board $s.Nic.Ip 4 32
    Add-EthRow 'ping after the ARP entry was cleared: lost' $p.Lost 'of 4' ($p.Lost -eq 0)
    $arp = & arp -a -N $s.Nic.Ip
    Write-EthLog ($arp -join "`n")
    $line = $arp | Select-String -SimpleMatch $board | Select-Object -First 1
    $hit = $false
    if ($line) { $hit = ($line.ToString().ToLower() -match [regex]::Escape($mac)) }
    Add-EthRow 'PC ARP table lists the board with its MAC' $(if ($line) { $line.ToString().Trim() } else { 'no entry' }) '' $hit
    $o = Send-EthCli $sp 'show arp'
    $after = 0; $repAfter = 0
    if ($o -match 'requests for us (\d+), replies sent (\d+)') { $after = [int]$Matches[1]; $repAfter = [int]$Matches[2] }
    Add-EthRow 'ARP responder: requests for us' ("{0} -> {1}" -f $before, $after) '' ($after -ge $before)
    Add-EthRow 'ARP responder: replies sent' ("{0} -> {1}" -f $repBefore, $repAfter) '' ($(if ($deleted) { $repAfter -gt $repBefore } else { $repAfter -ge $repBefore }))
} finally {
    if ($sp -and $sp.IsOpen) { $sp.Close() }
}
Complete-EthTest
