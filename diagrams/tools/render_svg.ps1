# Render a drawing set's SVG sheets (written by the build next to the .pptx) to PNG with headless Chrome,
# for hosts without LibreOffice. Same output names as render.ps1.
#   powershell -File diagrams\tools\render_svg.ps1 product-brief
# Input:  diagrams\out\svg\<set>-<n>.svg (960 x 540 pt)   Output: diagrams\out\png\<set>-<n>.png (1467 x 825, 110 dpi)
param([Parameter(Mandatory = $true)][string]$Set)
$ErrorActionPreference = 'Stop'

$out = Join-Path $PSScriptRoot '..\out' | Resolve-Path
$svgDir = Join-Path $out 'svg'
$pngDir = Join-Path $out 'png'
New-Item -ItemType Directory -Force -Path $pngDir | Out-Null
$chrome = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { throw 'Chrome or Edge not found' }
$profileDir = Join-Path $env:TEMP 'rtlnet_svg_chrome_profile'

$sheets = Get-ChildItem -Path $svgDir -Filter "$Set-*.svg"
if (-not $sheets) { throw "no SVG sheets for $Set in $svgDir (run node diagrams/src/$Set.js)" }
foreach ($svg in $sheets) {
    $png = Join-Path $pngDir ($svg.BaseName + '.png')
    $page = Join-Path $svgDir ($svg.BaseName + '.html')
    $body = Get-Content -Raw -Encoding utf8 $svg.FullName
    $body = $body -replace 'width="960" height="540"', 'width="1467" height="825"'
    $htmlText = "<!DOCTYPE html><html><head><meta charset=`"utf-8`"><style>html,body{margin:0;background:#fff;overflow:hidden}</style></head><body>$body</body></html>"
    [IO.File]::WriteAllText($page, $htmlText, (New-Object Text.UTF8Encoding $false))
    if (Test-Path $png) { Remove-Item $png }
    $ErrorActionPreference = 'Continue'
    & $chrome --headless --disable-gpu --hide-scrollbars "--user-data-dir=$profileDir" --force-device-scale-factor=1 `
        --window-size=1467,825 "--screenshot=$png" ('file:///' + ($page -replace '\\', '/')) 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    for ($i = 0; $i -lt 40 -and -not (Test-Path $png); $i++) { Start-Sleep -Milliseconds 250 }
    Remove-Item $page
    if (-not (Test-Path $png)) { throw "Chrome did not write $png" }
    $png
}
