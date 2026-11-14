<#
-------------------------------------------------------------------------------
File: link_test.ps1
Purpose: link control test of the Ethernet demo, board independent: `speed 100`, `speed 10` and `speed auto` on interface
  eth0 each renegotiate the link; the board's console and the PC adapter agree on the speed, and a ping still works.
Overview:
  * For each of speed 100, speed 10 and speed auto: configure it, wait (up to 25 s) for the board to report
    "eth0 is up, <n> Mb/s full duplex", read the PC adapter (-Nic) link speed (Get-NetAdapter): with -Direct (board cabled
    straight to the adapter) it must follow the board's speed, through a switch it keeps its own speed and must not be
    below the board's,
    check `show phy` (Advertised: only that full-duplex mode for 10 and 100; every full-duplex mode of the board for
    auto, no half duplex ever) and ping the board 10 times from the adapter's address without loss.
  * Speed auto must come back to the highest mode the PC adapter supports among 10/100/1000 (-AutoMbps, default 1000).
  * The board address is read from the console (`show ip`) after every renegotiation (a new lease is possible).
  * Final line: LINK_TEST: PASS n/n or LINK_TEST: FAIL f/n.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/link_test.ps1 -Port <COM port> -Nic <PC adapter> [-AutoMbps 1000] [-Direct] [-OutDir <dir>] [-Csv <file>]
Revision: 11-14-2026
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [Parameter(Mandatory = $true)][string]$Nic,
    [string]$Board = '',
    [int]$AutoMbps = 1000,
    [switch]$Direct,
    [string]$OutDir = '',
    [string]$Csv = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'eth_test_common.ps1')
Initialize-EthTest 'LINK_TEST' $OutDir $Csv
$s = Initialize-EthSession $Port $Nic $Board
$sp = $s.Sp
try {
    foreach ($step in @(@{ Cmd = 'speed 100'; Mbps = 100; Adv = '100f' }, @{ Cmd = 'speed 10'; Mbps = 10; Adv = '10f' }, @{ Cmd = 'speed auto'; Mbps = $AutoMbps; Adv = 'auto' })) {
        [void](Send-EthCli $sp 'configure terminal')
        [void](Send-EthCli $sp 'interface eth0')
        $o = Send-EthCli $sp $step.Cmd
        Add-EthRow "$($step.Cmd): accepted" (-not ($o -match '% ')) '' (-not ($o -match '% '))
        [void](Enter-EthPriv $sp)
        $linkOk = Wait-EthBoardLink $sp $step.Mbps
        Add-EthRow "$($step.Cmd): board link renegotiated" $step.Mbps 'Mb/s' $linkOk
        if ($Direct) {
            $nicOk = Wait-EthNicSpeed $Nic $step.Mbps
            $n = Get-EthNic $Nic
            Add-EthRow "$($step.Cmd): PC adapter link speed follows (direct cable)" $n.Mbps 'Mb/s' $nicOk
        } else {
            # Through a switch the PC adapter keeps its own speed: it is never below the board's.
            $n = Get-EthNic $Nic
            Add-EthRow "$($step.Cmd): PC adapter link speed (switch: at least the board's)" $n.Mbps 'Mb/s' ($n.Status -eq 'Up' -and $n.Mbps -ge $step.Mbps)
        }
        $o = Send-EthCli $sp 'show phy'
        $adv = ''
        if ($o -match 'Advertised\s+: ([^\r\n]+)') { $adv = $Matches[1].Trim() }
        if ($step.Adv -eq 'auto') {
            $advOk = ($adv -match '10f') -and ($adv -match '100f') -and ($adv -notmatch '10h|100h|1000h')
        } else {
            $advOk = ($adv -eq $step.Adv)
        }
        Add-EthRow "$($step.Cmd): advertised full-duplex set, no half duplex" $adv '' $advOk
        $nicNow = Get-EthNic $Nic
        $ip = Get-EthBoardIp $sp
        if (-not $ip -or $ip -eq '0.0.0.0') { Start-Sleep -Seconds 5; $ip = Get-EthBoardIp $sp }
        if ($ip -and $nicNow.Ip) {
            Start-Sleep -Seconds 2
            $p = Invoke-EthPing $ip $nicNow.Ip 10 64
            Add-EthRow "$($step.Cmd): ping x10 lost" $p.Lost 'of 10' ($p.Lost -eq 0)
            Add-EthRow "$($step.Cmd): ping round trip average" $p.AvgMs 'ms' ($p.AvgMs -ge 0)
        } else {
            Add-EthRow "$($step.Cmd): board address for ping" $ip '' $false
        }
    }
} finally {
    if ($sp -and $sp.IsOpen) { $sp.Close() }
}
Complete-EthTest
