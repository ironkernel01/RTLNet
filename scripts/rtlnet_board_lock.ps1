<#
-------------------------------------------------------------------------------
File: rtlnet_board_lock.ps1
Purpose: machine-wide lock for the Nexys Video board, shared with the other
  Claude session that uses the same board (project Commodore64). Dot-source it,
  then call Enter-RtlnetBoardLock at the start of every script that touches the
  board or hw_server.
Overview:
  * Lock file: %LOCALAPPDATA%\IronKernel\nexys_video.lock (override for tests
    only: $env:RTLNET_BOARD_LOCK). JSON fields: session, purpose, start (ISO
    time), expected_minutes, pid, host.
  * A board session spans several script runs (program, load, tests), so the
    lock is not delete-on-close and the scripts never release it; the session
    ends it with scripts/rtlnet_board.ps1 release (Exit-RtlnetBoardLock).
  * pid is the nearest long-lived ancestor of the script: walking the parent
    chain (Win32_Process ParentProcessId), the first process named claude*,
    node or Code; none found: the parent of the PowerShell process.
  * Stale: the pid no longer exists, or now is past start + expected_minutes + 30
    minutes. A stale lock is taken and a line says so.
  * A live, unexpired lock of another session ends the script at once with exit
    code 3 and a message naming holder, purpose and start; the script never
    waits and never takes the lock over. A lock of the caller's own session is
    reused and its start time refreshed.
  * Session name: $env:RTLNET_BOARD_SESSION when set, else 'rtlnet'. A caller
    may also set $script:RtlnetSession after dot-sourcing (rtlnet_board.ps1
    -Session does this).
  * The file is created atomically (FileMode CreateNew); after removing a
    stale lock the create is retried once.
Functions:
  * Enter-RtlnetBoardLock -Purpose <text> [-ExpectedMinutes 60]
  * Exit-RtlnetBoardLock     removes the lock when it belongs to this session
  * Get-RtlnetBoardLock      object (session, purpose, start, expected_minutes,
                             pid, host, State fresh|stale, Reason, Path) or $null
Revision: 11-09-2026
  * 11-09-2026: initial version.
  * 11-09-2026: RTLNET_BOARD_SESSION environment variable for the session name.
-------------------------------------------------------------------------------
#>

$script:RtlnetSession = if ($env:RTLNET_BOARD_SESSION) { $env:RTLNET_BOARD_SESSION } else { 'rtlnet' }
$script:StaleGraceMinutes = 30

function Get-RtlnetBoardLockPath {
    if ($env:RTLNET_BOARD_LOCK) { return $env:RTLNET_BOARD_LOCK }
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'IronKernel') 'nexys_video.lock')
}

# Nearest long-lived ancestor: claude*, node or Code; else the PowerShell parent.
function Get-RtlnetLongLivedPid {
    $procs = @{}
    foreach ($p in (Get-CimInstance Win32_Process)) { $procs[[int]$p.ProcessId] = $p }
    $cur = [int]$PID
    $firstParent = 0
    if ($procs.ContainsKey($cur)) { $firstParent = [int]$procs[$cur].ParentProcessId }
    $seen = @{}
    while ($procs.ContainsKey($cur) -and -not $seen.ContainsKey($cur)) {
        $seen[$cur] = $true
        $parent = [int]$procs[$cur].ParentProcessId
        if (-not $procs.ContainsKey($parent)) { break }
        $name = [string]$procs[$parent].Name
        if ($name -like 'claude*' -or $name -ieq 'node.exe' -or $name -ieq 'node' -or $name -ieq 'Code.exe' -or $name -ieq 'Code') {
            return $parent
        }
        $cur = $parent
    }
    return $firstParent
}

function Get-RtlnetBoardLock {
    $path = Get-RtlnetBoardLockPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $info = [ordered]@{ session = ''; purpose = ''; start = ''; expected_minutes = 0; pid = 0; host = '';
                        State = 'fresh'; Reason = ''; Path = $path }
    $json = $null
    try {
        $text = [System.IO.File]::ReadAllText($path)
        $json = $text | ConvertFrom-Json
    } catch { $json = $null }
    if ($null -eq $json -or -not $json.session) {
        # Unreadable: a writer may be mid-create. Older than a minute: stale.
        $age = (Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime
        $info.session = 'unknown'
        $info.purpose = 'unreadable lock file'
        if ($age.TotalMinutes -gt 1) { $info.State = 'stale'; $info.Reason = 'unreadable and older than 1 minute' }
        return [pscustomobject]$info
    }
    $info.session = [string]$json.session
    $info.purpose = [string]$json.purpose
    $info.start = [string]$json.start
    $info.expected_minutes = [int]$json.expected_minutes
    $info.pid = [int]$json.pid
    $info.host = [string]$json.host
    $alive = $null -ne (Get-Process -Id $info.pid -ErrorAction SilentlyContinue)
    $startOk = $true
    try { $t0 = [System.DateTimeOffset]::Parse($info.start) } catch { $startOk = $false }
    if (-not $alive) {
        $info.State = 'stale'; $info.Reason = "pid $($info.pid) no longer exists"
    } elseif (-not $startOk) {
        $info.State = 'stale'; $info.Reason = 'start time unreadable'
    } else {
        $limit = $t0.AddMinutes($info.expected_minutes + $script:StaleGraceMinutes)
        if ([System.DateTimeOffset]::Now -gt $limit) {
            $info.State = 'stale'
            $info.Reason = "past start + $($info.expected_minutes) + $($script:StaleGraceMinutes) minutes"
        }
    }
    return [pscustomobject]$info
}

function Write-RtlnetBoardLockFile([string]$Path, [string]$Purpose, [int]$ExpectedMinutes, [bool]$CreateNew) {
    $obj = [ordered]@{
        session          = $script:RtlnetSession
        purpose          = $Purpose
        start            = (Get-Date).ToString('o')
        expected_minutes = $ExpectedMinutes
        pid              = (Get-RtlnetLongLivedPid)
        host             = $env:COMPUTERNAME
    }
    $bytes = [System.Text.Encoding]::ASCII.GetBytes(($obj | ConvertTo-Json))
    if ($CreateNew) {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read)
        try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush() } finally { $fs.Dispose() }
    } else {
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    }
}

function Enter-RtlnetBoardLock {
    param(
        [Parameter(Mandatory = $true)][string]$Purpose,
        [int]$ExpectedMinutes = 60
    )
    $path = Get-RtlnetBoardLockPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $lock = Get-RtlnetBoardLock
        if ($null -ne $lock) {
            if ($lock.State -eq 'stale') {
                Write-Output ("RTLNET_BOARD_LOCK: taking stale lock of session {0} (purpose '{1}', start {2}): {3}" -f
                    $lock.session, $lock.purpose, $lock.start, $lock.Reason)
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            } elseif ($lock.session -eq $script:RtlnetSession) {
                Write-RtlnetBoardLockFile $path $Purpose $ExpectedMinutes $false
                Write-Output "RTLNET_BOARD_LOCK: reusing own lock ($Purpose, start refreshed)"
                return
            } else {
                $msg = "RTLNET_BOARD_LOCK: FAIL board is held by session '{0}' (purpose '{1}', start {2}, pid {3}); not waiting, not taking over"
                Write-Output ($msg -f $lock.session, $lock.purpose, $lock.start, $lock.pid)
                exit 3
            }
        }
        try {
            Write-RtlnetBoardLockFile $path $Purpose $ExpectedMinutes $true
            Write-Output "RTLNET_BOARD_LOCK: taken ($Purpose, $ExpectedMinutes min)"
            return
        } catch [System.IO.IOException] {
            # Created by the other session between the check and the create: look again.
        }
    }
    Write-Output 'RTLNET_BOARD_LOCK: FAIL could not create the lock file (another session took it)'
    exit 3
}

function Exit-RtlnetBoardLock {
    $path = Get-RtlnetBoardLockPath
    $lock = Get-RtlnetBoardLock
    if ($null -eq $lock) { Write-Output 'RTLNET_BOARD_LOCK: no lock held'; return }
    if ($lock.session -ne $script:RtlnetSession) {
        Write-Output ("RTLNET_BOARD_LOCK: lock belongs to session '{0}' (purpose '{1}'), not released" -f $lock.session, $lock.purpose)
        return
    }
    Remove-Item -LiteralPath $path -Force
    Write-Output 'RTLNET_BOARD_LOCK: released'
}
