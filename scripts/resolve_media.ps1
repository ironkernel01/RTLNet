param([string]$IronCapture = $env:IRONCAPTURE_ROOT, [string]$IronH264 = $env:IRONH264_ROOT)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$ip = Join-Path $repo 'ip'
$null = New-Item -Path $ip -ItemType Directory -Force
$pins = Get-Content -Raw (Join-Path $repo 'media-sources.json') | ConvertFrom-Json
foreach ($item in $pins) {
    $root = if ($item.name -eq 'IronCapture') { $IronCapture } else { $IronH264 }
    $link = Join-Path $ip $item.core
    if (!$root) {
        if (Test-Path -LiteralPath $link) {
            $target = (Get-Item -LiteralPath $link).Target
            if ($target) { $root = Split-Path (Split-Path $target[0]) }
        }
        if (!$root) { $root = Join-Path (Split-Path $repo) $item.name }
    }
    if (!$root) { throw "Supply the $($item.name) checkout at $($item.commit) using -$($item.name)." }
    $root = (Resolve-Path -LiteralPath $root).Path
    $origin = git -C $root remote get-url origin
    if (($origin -replace '^https://[^/@]+@github\.com/', 'https://github.com/') -ne $item.repository) { throw "Unexpected $($item.name) origin" }
    if ((git -C $root rev-parse "HEAD:ip/$($item.core)") -ne $item.tree) { throw "Expected $($item.name) at $($item.commit)" }
    if (git -C $root status --porcelain -- "ip/$($item.core)") { throw "Local edits in $($item.name) media core" }
    $target = (Resolve-Path -LiteralPath (Join-Path $root "ip/$($item.core)")).Path
    if (Test-Path -LiteralPath $link) {
        $current = Get-Item -LiteralPath $link
        if (!$current.Target -or [IO.Path]::GetFullPath($current.Target[0]) -ne $target) { throw "Existing $link does not point to $target" }
    } else {
        $null = New-Item -ItemType Junction -Path $link -Target $target
    }
    Write-Output "$($item.name) $($item.commit) $target"
}
