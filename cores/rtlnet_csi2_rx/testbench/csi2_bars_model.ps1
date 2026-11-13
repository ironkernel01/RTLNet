<#
-------------------------------------------------------------------------------
File: csi2_bars_model.ps1
Purpose: build the host C model of the rtlnet_csi2_rx test patterns (csi2_bars_model.c) with the host gcc from
  rtlnet_tools.ps1 and run it. Without a switch it prints the MODEL lines (static-bars frame size and CRC-32 per video mode)
  and exits 0; with -SelfTest it runs the CRC engine check (crc32("123456789") = 0xCBF43926) and exits 0 only on PASS.
  -Verify (the regression entry) runs the self test, regenerates the CRC tables of the benches (pattern_crc_full.mem,
  pattern_crc_small.mem) and fails if the committed files differ, then runs pattern_model.py
  --verify-c (the numpy model against the C model, byte for byte); the last line is "CSI2_BARS_MODEL: PASS".
  -WriteMem rewrites the two table files from the C model.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File csi2_bars_model.ps1 [-SelfTest | -Verify | -WriteMem |
  -Dump <file> -Mode <720p30|1080p30>]
Revision: 11-13-2026
  * 11-13-2026: pattern_model.py lives next to this script; the stream_check.py selftest moved to the board regression list.
  * 11-10-2026: -Verify, -WriteMem (pattern CRC tables, Python model cross check).
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [switch]$SelfTest,
    [switch]$Verify,
    [switch]$WriteMem,
    [string]$Dump = '',
    [string]$Mode = '720p30'
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Cc = Resolve-RtlnetHostCc
$env:PATH = "$(Split-Path -Parent $Cc);$env:PATH"
$exe = Join-Path (Get-RtlnetToolDir 'csi2_bars') 'csi2_bars_model.exe'
& $Cc -std=c11 -Wall -Wextra -Werror -pedantic -O2 "$PSScriptRoot/csi2_bars_model.c" -o $exe
if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_BARS_MODEL: FAIL build'; exit 1 }
$MemFull  = Join-Path $PSScriptRoot 'pattern_crc_full.mem'
$MemSmall = Join-Path $PSScriptRoot 'pattern_crc_small.mem'
if ($WriteMem) {
    & $exe --crc-mem $MemFull
    if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_BARS_MODEL: FAIL crc-mem'; exit 1 }
    & $exe --crc-mem-small $MemSmall
    if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_BARS_MODEL: FAIL crc-mem-small'; exit 1 }
    Write-Output 'CSI2_BARS_MODEL: PASS tables written'
    exit 0
}
if ($Verify) {
    $out = & $exe --selftest
    $out | Write-Output
    if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_BARS_MODEL: FAIL self test'; exit 1 }
    $tmp = Get-RtlnetToolDir 'csi2_bars'
    foreach ($t in @(@('--crc-mem', $MemFull), @('--crc-mem-small', $MemSmall))) {
        $gen = Join-Path $tmp ([System.IO.Path]::GetFileName($t[1]))
        & $exe $t[0] $gen
        if ($LASTEXITCODE -ne 0) { Write-Output "CSI2_BARS_MODEL: FAIL $($t[0])"; exit 1 }
        $a = [System.IO.File]::ReadAllText($gen).Replace("`r`n", "`n")
        $b = if (Test-Path -LiteralPath $t[1]) { [System.IO.File]::ReadAllText($t[1]).Replace("`r`n", "`n") } else { '' }
        if ($a -ne $b) { Write-Output "CSI2_BARS_MODEL: FAIL $([System.IO.Path]::GetFileName($t[1])) differs from the C model (run -WriteMem)"; exit 1 }
        Write-Output "TABLE $([System.IO.Path]::GetFileName($t[1])) equals the C model"
    }
    $py = Resolve-RtlnetPython
    & $py -I (Join-Path $PSScriptRoot 'pattern_model.py') --verify-c $exe
    if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_BARS_MODEL: FAIL python model'; exit 1 }
    Write-Output 'CSI2_BARS_MODEL: PASS'
    exit 0
}
if ($SelfTest) {
    $out = & $exe --selftest
    $out | Write-Output
    if ($LASTEXITCODE -ne 0) { Write-Output 'CSI2_BARS_MODEL: FAIL self test'; exit 1 }
    Write-Output 'CSI2_BARS_MODEL: PASS'
    exit 0
}
if ($Dump) {
    & $exe --dump $Dump $Mode
    exit $LASTEXITCODE
}
& $exe | Write-Output
exit $LASTEXITCODE
