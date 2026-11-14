<#
-------------------------------------------------------------------------------
File: console_test.ps1
Purpose: console and CLI test of the Ethernet demo firmware over the USB-UART, board independent.
Overview:
  * Soft restart (`reload`): the start-up banner (firmware name, board ID, build ID), the PHY and network bring-up lines
    and the first prompt appear within 20 s.
  * `show version` (system block ETHS, board, CPU clock, link modes, build ID, firmware), `show system` (clocks locked,
    uptime, switches, buttons, LEDs), `show phy` (PHY ID, driver, link), `show interfaces`, `show ip`.
  * Help: `?` lists the user exec commands, an unknown command is rejected with the error marker, abbreviations and the
    enable / configure terminal / exit mode changes work, and the removed link commands (duplex, advertise, autoneg)
    do not exist: the link has `speed 10|100|auto` only.
  * Final line: CONSOLE_TEST: PASS n/n or CONSOLE_TEST: FAIL f/n; transcript in <OutDir>/console_test_transcript.txt.
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/console_test.ps1 -Port <COM port> -Nic <PC adapter> [-OutDir <dir>] [-Csv <file>]
Revision: 11-14-2026
  * 11-14-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [string]$Nic = '',
    [string]$Board = '',
    [string]$OutDir = '',
    [string]$Csv = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'eth_test_common.ps1')
Initialize-EthTest 'CONSOLE_TEST' $OutDir $Csv
$sp = $null
try { $sp = Open-EthConsole $Port } catch { Write-Output "CONSOLE_TEST: FAIL cannot open ${Port}: $($_.Exception.Message)"; exit 1 }
try {
    if (-not (Enter-EthPriv $sp)) { Write-Output "CONSOLE_TEST: FAIL no CLI prompt on $Port"; exit 1 }

    # Soft restart: the banner and the bring-up lines.
    $sp.Write("reload`r")
    $buf = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 20) {
        $buf += $sp.ReadExisting()
        if (($buf -replace "`r", '') -match 'Type \? for help\.[\s\S]*rtlnet>') { Start-Sleep -Milliseconds 500; $buf += $sp.ReadExisting(); break }
        Start-Sleep -Milliseconds 50
    }
    $buf = $buf -replace "`r", ''
    Write-EthLog $buf
    Add-EthRow 'banner: firmware name' ($buf -match 'RTLNet Ethernet demo -- rtlnet-eth-fw') '' ($buf -match 'RTLNet Ethernet demo -- rtlnet-eth-fw')
    $bm = [regex]::Match($buf, 'Board (\S{4}), build ([0-9a-f]{8})')
    Add-EthRow 'banner: board ID and build ID' $bm.Value '' $bm.Success
    Add-EthRow 'bring-up: PHY line' ($buf -match 'PHY: .* ID 0x[0-9A-F]{8} at address \d+') '' ($buf -match 'PHY: .* ID 0x[0-9A-F]{8} at address \d+')
    Add-EthRow 'bring-up: network and CPU path lines' ($buf -match 'Network: MAC ok, MDIO ok, PHY ok' -and $buf -match 'CPU path: DMA ok') '' ($buf -match 'Network: MAC ok, MDIO ok, PHY ok' -and $buf -match 'CPU path: DMA ok')
    Add-EthRow 'first prompt rtlnet>' ($buf -match 'rtlnet>') '' ($buf -match 'rtlnet>')
    [void](Enter-EthPriv $sp)

    $o = Send-EthCli $sp 'show version'
    Add-EthRow 'show version: system block ETHS' ($o -match 'System block\s+: ETHS') '' ($o -match 'System block\s+: ETHS')
    $m = [regex]::Match($o, 'CPU clock\s+: (\d+) Hz')
    Add-EthRow 'show version: CPU clock' $m.Groups[1].Value 'Hz' ($m.Success -and [int64]$m.Groups[1].Value -ge 50000000)
    $m = [regex]::Match($o, 'Link modes\s+: ([0-9 ]+)\(full duplex\)')
    Add-EthRow 'show version: link modes' $m.Groups[1].Value.Trim() '' $m.Success
    Add-EthRow 'show version: build ID and tree state' ($o -match 'Build ID\s+: 0x[0-9a-f]{8} \(git [0-9a-f]{8}\), tree (clean|dirty)') '' ($o -match 'Build ID\s+: 0x[0-9a-f]{8} \(git [0-9a-f]{8}\), tree (clean|dirty)')
    Add-EthRow 'show version: firmware line' ($o -match 'Firmware\s+: rtlnet-eth-fw') '' ($o -match 'Firmware\s+: rtlnet-eth-fw')
    Add-EthRow 'show version: CPU path blocks' ($o -match 'classifier yes, checksum offload TX yes, RX yes') '' ($o -match 'classifier yes, checksum offload TX yes, RX yes')

    $o = Send-EthCli $sp 'show system'
    Add-EthRow 'show system: clocks locked' ($o -match 'Clocks\s+: locked') '' ($o -match 'Clocks\s+: locked')
    Add-EthRow 'show system: uptime, switches, buttons, LEDs' ($o -match 'Uptime' -and $o -match 'Switches\s+: 0x' -and $o -match 'Buttons\s+: 0x' -and $o -match 'LEDs\s+: 0x') '' ($o -match 'Uptime' -and $o -match 'Switches\s+: 0x' -and $o -match 'Buttons\s+: 0x' -and $o -match 'LEDs\s+: 0x')
    $o = Send-EthCli $sp 'show phy'
    Add-EthRow 'show phy: ID and driver' ($o -match 'ID 0x[0-9A-F]{8}, driver ') '' ($o -match 'ID 0x[0-9A-F]{8}, driver ')
    $o = Send-EthCli $sp 'show interfaces'
    Add-EthRow 'show interfaces: eth0 and MAC status' ($o -match 'eth0 is (up|down)' -and $o -match 'MAC speed') '' ($o -match 'eth0 is (up|down)' -and $o -match 'MAC speed')
    $o = Send-EthCli $sp 'show ip'
    Add-EthRow 'show ip: node MAC and addresses' ($o -match 'Node MAC' -and $o -match 'Effective IPv4') '' ($o -match 'Node MAC' -and $o -match 'Effective IPv4')

    $o = Send-EthCli $sp '?'
    Add-EthRow 'help lists show, enable' ($o -match 'show version' -and $o -match 'enable') '' ($o -match 'show version' -and $o -match 'enable')
    $o = Send-EthCli $sp 'bogus'
    Add-EthRow 'unknown command rejected' ($o -match "Invalid input detected at '\^' marker") '' ($o -match "Invalid input detected at '\^' marker")
    $o = Send-EthCli $sp 'sh ver'
    Add-EthRow 'abbreviation: sh ver' ($o -match 'System block') '' ($o -match 'System block')
    $o = Send-EthCli $sp 'configure terminal'
    Add-EthRow 'configure terminal' ($o -match 'rtlnet\(config\)#') '' ($o -match 'rtlnet\(config\)#')
    $o = Send-EthCli $sp 'interface eth0'
    Add-EthRow 'interface eth0' ($o -match 'rtlnet\(config-if\)#') '' ($o -match 'rtlnet\(config-if\)#')
    foreach ($c in @('duplex half', 'advertise 10f', 'autoneg', 'speed 1000')) {
        $o = Send-EthCli $sp $c
        Add-EthRow "removed or invalid link command refused: $c" ($o -match '% Invalid') '' ($o -match '% Invalid')
    }
    [void](Enter-EthPriv $sp)
    $o = Send-EthCli $sp 'show running-config'
    Add-EthRow 'show running-config has speed and end' ($o -match ' speed (auto|10|100)' -and $o -match '\nend') '' ($o -match ' speed (auto|10|100)' -and $o -match '\nend')
} finally {
    if ($sp -and $sp.IsOpen) { $sp.Close() }
}
Complete-EthTest
