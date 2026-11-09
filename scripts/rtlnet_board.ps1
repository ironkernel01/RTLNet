<#
-------------------------------------------------------------------------------
File: rtlnet_board.ps1
Purpose: command line for the machine-wide Nexys Video board lock
  (scripts/rtlnet_board_lock.ps1).
Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_board.ps1 take -Purpose "ddr3 tests" -Minutes 60
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_board.ps1 show
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_board.ps1 release
  * take: takes or reuses the lock (exit 3 when another session holds it).
  * show: prints the lock and its state (fresh or stale); exit 0.
  * release: removes the lock when it belongs to this session.
  * -Session <name>: session name for take and release; default
    $env:RTLNET_BOARD_SESSION, else 'rtlnet'.
Revision: 11-09-2026
  * 11-09-2026: initial version.
  * 11-09-2026: -Session parameter.
-------------------------------------------------------------------------------
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet('take', 'release', 'show')][string]$Command,
    [string]$Purpose = 'rtlnet board session',
    [int]$Minutes = 60,
    [string]$Session = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rtlnet_board_lock.ps1')
if ($Session) { $script:RtlnetSession = $Session }
switch ($Command) {
    'take'    { Enter-RtlnetBoardLock -Purpose $Purpose -ExpectedMinutes $Minutes }
    'release' { Exit-RtlnetBoardLock }
    'show' {
        $l = Get-RtlnetBoardLock
        if ($null -eq $l) { Write-Output 'RTLNET_BOARD_LOCK: none' }
        else {
            Write-Output ("RTLNET_BOARD_LOCK: session={0} purpose='{1}' start={2} expected_minutes={3} pid={4} host={5} state={6}{7}" -f
                $l.session, $l.purpose, $l.start, $l.expected_minutes, $l.pid, $l.host, $l.State,
                $(if ($l.Reason) { " ($($l.Reason))" } else { '' }))
        }
    }
}
exit 0
