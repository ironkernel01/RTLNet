<#
Purpose: build the Zybo Z7-20 camera baseline through the shared Vivado launcher.
Overview: each tag owns its project, reports and gated exports; no programming.
Revision: 11-14-2026. Initial camera baseline flow.
#>
param(
    [ValidatePattern('^[A-Za-z0-9_]{1,24}$')][string]$Tag = 'camera',
    [ValidateSet('camera','baseline')][string]$Stage = 'camera',
    [ValidatePattern('^[A-Za-z0-9_]{1,24}$')][string]$CameraTag = 'camera',
    [ValidateSet('none','full','demo')][string]$HighProfile = 'none',
    [ValidateSet('cabac','t8','all')][string]$HpTools = 'all',
    [string]$HpNetlist = '',
    [ValidateSet('original','explore','holdfix')][string]$Implementation = 'holdfix',
    [ValidateSet('none','bd')][string]$StopAfter = 'none'
)
$ErrorActionPreference = 'Stop'
$ReturnCode=1
$Build=$null
try {
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo = (Resolve-Path (Join-Path $Board '..\..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$null = Resolve-RtlnetXilinx
# The Digilent IP and board files are third-party material that may be absent from a checkout.
foreach ($Required in 'ip/digilent/NOTICE.txt', 'board_files/zybo-z7-20/A.0/board.xml') {
    if (-not (Test-Path -LiteralPath (Join-Path $Board $Required))) {
        throw ('third-party Digilent files are missing (boards/zybo_z7_20/' + $Required + '). Populate them with: ' +
            'python boards/zybo_z7_20/scripts/rtlnet_import_camera.py --hw-archive <Zybo-Z7-20-Pcam-5C-hw.xpr.zip> ' +
            '--board-files <folder containing zybo-z7-20/A.0/board.xml> (or set RTLNET_ZYBO_HW_ARCHIVE and ' +
            'RTLNET_ZYBO_BOARD_FILES). The import checks the archive SHA-256; the build checks every IP file hash. See the README, Third-party IP.')
    }
}
if ($HighProfile -ne 'none') {
    if (-not $HpNetlist -or -not (Test-Path -LiteralPath (Join-Path $HpNetlist 'rtlnet_h264_hp.edf'))) {
        throw 'RTLNET_BUILD: FAIL missing explicitly supplied -HpNetlist folder (rtlnet_h264_hp.edf)'
    }
    if ($Stage -ne 'baseline') { throw 'RTLNET_BUILD: FAIL High profile requires -Stage baseline' }
    $deliveryInfo=Join-Path $HpNetlist 'netlist_info.txt'
    if(-not(Test-Path -LiteralPath $deliveryInfo) -or
        [System.IO.File]::ReadAllText($deliveryInfo) -notmatch '(?i)xc7z020clg400-1') {
        throw 'RTLNET_BUILD: FAIL netlist_info.txt must identify xc7z020clg400-1 delivery'
    }
}
if ($Stage -eq 'baseline') {
    $CameraInfo = Join-Path $Board "build/$CameraTag/build_info.txt"
    if (-not (Test-Path -LiteralPath $CameraInfo) -or
        [System.IO.File]::ReadAllText($CameraInfo) -notmatch '(?m)^gate_pass\s+1\s*$') {
        throw "RTLNET_BUILD: FAIL stage 0 gate is not recorded for camera tag $CameraTag"
    }
    $CameraEvidence=[IO.File]::ReadAllText($CameraInfo)
    if($CameraEvidence -notmatch '(?m)^stage camera\s*$' -or
       $CameraEvidence -notmatch '(?m)^part xc7z020clg400-1\s*$') {
        throw 'Camera prerequisite has the wrong stage or part'
    }
}
$Build = Join-Path $Board "build/$Tag"
New-Item -ItemType Directory -Force -Path $Build | Out-Null
$Python = Resolve-RtlnetPython
if($Python.Contains(',')){throw 'Resolved Python path contains an unsupported Tcl argument separator'}
if($Stage -eq 'baseline') {
    & $Python -I (Join-Path $PSScriptRoot 'check_baseline_sources.py') --manifest (Join-Path $Build 'baseline_sources.tcl')
    if($LASTEXITCODE -ne 0){throw 'Baseline source closure check fails before Vivado'}
}
& $Python -I (Join-Path $PSScriptRoot 'rtlnet_prepare_camera_ip.py') $Build
if ($LASTEXITCODE -ne 0) { throw 'RTLNET_BUILD: FAIL camera IP preparation' }
if($HighProfile -ne 'none') {
    $hash=(Get-FileHash -LiteralPath (Join-Path $HpNetlist 'rtlnet_h264_hp.edf') -Algorithm SHA256).Hash
    $provenance="hp_edif_sha256 $hash`nhp_variant $HighProfile`nhp_tools $HpTools`n"+[System.IO.File]::ReadAllText($deliveryInfo)
    [System.IO.File]::WriteAllText((Join-Path $Build 'hp_delivery.txt'),$provenance,(New-Object System.Text.UTF8Encoding($false)))
}
$BuildArgs = "tag,$Tag,stage,$Stage,highprofile,$HighProfile,implementation,$Implementation,stop,$StopAfter,python," + ($Python -replace '\\','/')
if ($HighProfile -ne 'none') {
    $BuildArgs += ',hp_netlist,' + ((Resolve-Path -LiteralPath $HpNetlist).Path -replace '\\','/')
    $BuildArgs += ",hp_t8,$(if ($HpTools -eq 'cabac') {0} else {1}),hp_auto,$(if ($HpTools -eq 'all') {1} else {0})"
}
& (Join-Path $Repo 'scripts/rtlnet_vivado.ps1') -MaxSlots 2 `
    -Tcl (Join-Path $PSScriptRoot 'build_bitstream.tcl') `
    -Log (Join-Path $Build 'build_bitstream.log') -TclArgs $BuildArgs
$ReturnCode=$LASTEXITCODE
if($ReturnCode -ne 0){throw "Vivado launcher exits $ReturnCode; see build/$Tag/build_bitstream.log"}
if($StopAfter -eq 'bd'){
    Write-Output "RTLNET_BUILD: STOP after block design validation, tag $Tag (debug, no verdict)"
    exit 0
}
$ReturnCode=44
foreach($Artifact in 'rtlnet_zybo_z7_20.bit','rtlnet_zybo_z7_20.xsa','build_info.txt','export_manifest.txt') {
    $Path=Join-Path $Build $Artifact
    if(-not(Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        throw "Missing completed export $Artifact"
    }
}
if([IO.File]::ReadAllText((Join-Path $Build 'build_info.txt')) -notmatch '(?m)^gate_pass\s+1\s*$') {
    throw 'Vivado exits zero without gate_pass 1'
}
Write-Output "RTLNET_BUILD: PASS stage $Stage tag $Tag"
exit 0
} catch {
    $FailureMessage=$_.Exception.Message
    if($ReturnCode -eq 0){$ReturnCode=1}
    # Cleanup applies only to this tag, never to the prerequisite camera tag.
    try {
    if($Build) {
        foreach($Artifact in 'rtlnet_zybo_z7_20.bit','rtlnet_zybo_z7_20.xsa','export_manifest.txt') {
            $Path=Join-Path $Build $Artifact
            if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force}
        }
        $InfoPath=Join-Path $Build 'build_info.txt'
        if(Test-Path -LiteralPath $InfoPath){
            $Contents=[regex]::Replace([IO.File]::ReadAllText($InfoPath),'(?m)^gate_pass\s+1\s*$','')
            [IO.File]::WriteAllText($InfoPath,$Contents,(New-Object Text.UTF8Encoding($false)))
        }
    }
    } catch {$FailureMessage += "; cleanup: $($_.Exception.Message)"}
    Write-Output "RTLNET_BUILD: FAIL ($ReturnCode) stage $Stage tag $Tag $FailureMessage"
    exit $ReturnCode
}
