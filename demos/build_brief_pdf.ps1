# build_brief_pdf.ps1 - Markdown to PDF for a demo brief (headless Chrome, pdf_generator.md).
#   powershell -NoProfile -ExecutionPolicy Bypass -File demos\build_brief_pdf.ps1 h264_baseline
# Reads demos\<Name>\<Name>_brief.md and writes demos\<Name>\<Name>_brief.pdf.
# The page is the Markdown between documentation\pdf\head.html and foot.html, the same shell and the same
# Chrome printing as documentation\build_pdf.ps1. render.html is assembled next to the .md so the relative
# drawing paths (..\..\diagrams\out\png) resolve, and is deleted after the print.
param([Parameter(Mandatory = $true)][string]$Name)
$ErrorActionPreference = 'Stop'

$demos = $PSScriptRoot
$pdfDir = Join-Path $demos '..\documentation\pdf'
$dir = Join-Path $demos $Name
$md = Join-Path $dir "${Name}_brief.md"
$pdf = Join-Path $dir "${Name}_brief.pdf"
$render = Join-Path $dir 'render.html'
$profileDir = Join-Path $env:TEMP 'rtlnet_pdf_chrome_profile'
if (-not (Test-Path $md)) { throw "$md not found" }

$chrome = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { throw 'Chrome or Edge not found' }

$mdText = Get-Content -Raw -Encoding utf8 $md
if ($mdText.Contains('</script>')) { throw "$md contains </script>, which would end the page source" }

# Every image the brief references must exist: a missing PNG prints as an empty box.
$missing = [regex]::Matches($mdText, '!\[[^\]]*\]\(([^)]+\.png)\)|<img[^>]*\ssrc="([^"]+\.png)"') |
    ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } } |
    Where-Object { -not (Test-Path (Join-Path $dir $_)) }
if ($missing) { throw "missing image(s): $($missing -join ', ')" }

$assembled = (Get-Content -Raw -Encoding utf8 (Join-Path $pdfDir 'head.html')) + $mdText +
    (Get-Content -Raw -Encoding utf8 (Join-Path $pdfDir 'foot.html'))
[IO.File]::WriteAllText($render, $assembled, (New-Object Text.UTF8Encoding $false))

if (Test-Path $pdf) { Remove-Item $pdf }
$url = 'file:///' + ((Resolve-Path $render).Path -replace '\\', '/')
# Chrome logs to stderr; Windows PowerShell turns native stderr into error records, so the call runs
# under Continue and the PDF check decides.
$ErrorActionPreference = 'Continue'
& $chrome --headless --disable-gpu --no-pdf-header-footer "--user-data-dir=$profileDir" `
    --virtual-time-budget=30000 --run-all-compositor-stages-before-draw `
    "--print-to-pdf=$pdf" $url 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'
for ($i = 0; $i -lt 60 -and -not (Test-Path $pdf); $i++) { Start-Sleep -Milliseconds 500 }
Remove-Item $render
if (-not (Test-Path $pdf)) { throw "Chrome did not write $pdf" }
"wrote $pdf ($((Get-Item $pdf).Length) bytes)"
