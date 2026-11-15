<#
Purpose: check board-bench Annex B output with the repository's three reference decoders.
Overview: driver-generated SPS/PPS, h264_check.py assembly/comparison, JM/OpenH264/FFmpeg;
  a mutated reconstruction proves that the comparison refuses incorrect decoded pixels.
Revision: 11-14-2026. Runs the board bench itself through the repository simulator runner (own tag, own work
  folder), so the check needs no earlier run and tolerates parallel regression entries.
#>
param([string]$Tag = 'decoder')
$ErrorActionPreference = 'Stop'
if ($Tag -notmatch '^[A-Za-z0-9_]+$') { throw 'invalid simulation tag' }
$Board = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Repo = (Resolve-Path (Join-Path $Board '..\..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Py = Resolve-RtlnetPython
$Cc = Resolve-RtlnetHostCc
$Ff = Resolve-RtlnetFfmpeg
$Jm = Resolve-RtlnetLdecod
$Oh = Resolve-RtlnetH264dec
if (-not $Jm -or -not $Oh) { throw 'reference decoders missing (Resolve-RtlnetLdecod / Resolve-RtlnetH264dec); see scripts/rtlnet_tools.ps1' }
$env:PATH = "$(Split-Path -Parent $Cc);$env:PATH"
# The bench writes board_stream.hex, board_rec0.hex and board_info.txt into its simulator work folder.
$Bench = 'tb_rtlnet_zybo_video'
Push-Location $Repo
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts/rtlnet_run_sim.ps1') `
        -Bench $Bench -Filelist "boards/zybo_z7_20/testbench/$Bench.f" -Tag $Tag
    if ($LASTEXITCODE -ne 0) { throw "board bench simulation failed (tag $Tag)" }
} finally { Pop-Location }
$Run = Join-Path $Repo ".sim/${Bench}_$Tag"
foreach ($Name in 'board_stream.hex', 'board_rec0.hex', 'board_info.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $Run $Name))) { throw "board bench output missing: $Run/$Name" }
}
$Tb = Join-Path $Repo 'cores/rtlnet_h264_enc/testbench'
$Check = Join-Path $Tb 'h264_check.py'
$Sps = Join-Path $Run 'spspps.exe'
& $Cc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST "-I$Repo/cores/rtlnet_common/driver" `
    "-I$Repo/cores/rtlnet_h264_enc/driver" "$Repo/cores/rtlnet_h264_enc/driver/rtlnet_h264_enc.c" `
    "$Tb/h264_spspps_tool.c" -o $Sps
if ($LASTEXITCODE -ne 0) { throw 'SPS/PPS writer compilation failed' }
& $Sps 32 16 32 16 30 4 (Join-Path $Run 'sps.bin')
if ($LASTEXITCODE -ne 0) { throw 'SPS/PPS generation failed' }
& $Py -I $Check assemble --dir $Run --prefix (Join-Path $Run 'board') --spspps (Join-Path $Run 'sps.bin') --pics 1 --disp-h 16
if ($LASTEXITCODE -ne 0) { throw 'repository stream assembly failed' }
function Decode([string]$Name, [string]$Exe, [string[]]$Arguments) {
    $stdout = Join-Path $Run "$Name.log"
    $stderr = Join-Path $Run "$Name.err"
    $Process = Start-Process -FilePath $Exe -ArgumentList $Arguments -WorkingDirectory $Run -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $null = $Process.Handle
    if (-not $Process.WaitForExit(60000)) { $Process.Kill(); throw "$Name decoder timeout" }
    if ($Process.ExitCode -ne 0) { throw "$Name decoder exit $($Process.ExitCode)" }
    $LogText = [System.IO.File]::ReadAllText($stdout) + [System.IO.File]::ReadAllText($stderr)
    if ($Name -eq 'jm') {
        $LogText += [System.IO.File]::ReadAllText((Join-Path $Run 'log.dec'))
        if ($LogText -notmatch '1 frames are decoded' -or $LogText -match '(?i)\berror\b') { throw 'JM decode log failed' }
    } elseif ($Name -eq 'oh') {
        if ($LogText -notmatch 'Frames:\s+1\b' -or $LogText -match '(?i)(\berror\b|fail)') { throw 'OpenH264 decode log failed' }
    } elseif ($LogText.Trim().Length -ne 0) { throw 'FFmpeg reported a decoder error' }
    & $Py -I $Check compare --a (Join-Path $Run 'rebuilt0.yuv') --b (Join-Path $Run "dec_$Name.yuv") `
        --w 32 --h 16 --label "zybo_$Name"
    if ($LASTEXITCODE -ne 0) { throw "$Name reconstruction mismatch" }
}
Decode 'jm' $Jm @('-i','stream.264','-o','dec_jm.yuv')
Decode 'oh' $Oh @('stream.264','dec_oh.yuv')
Decode 'ff' $Ff.Ffmpeg @('-y','-v','error','-i','stream.264','-f','rawvideo','-pix_fmt','yuv420p','dec_ff.yuv')
$Probe = & $Ff.Ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 (Join-Path $Run 'stream.264')
if ($LASTEXITCODE -ne 0 -or $Probe -ne '32,16') { throw "unexpected decoded dimensions $Probe" }
$Bad = [System.IO.File]::ReadAllBytes((Join-Path $Run 'rebuilt0.yuv'))
$Bad[0] = $Bad[0] -bxor 1
[System.IO.File]::WriteAllBytes((Join-Path $Run 'mutated.yuv'), $Bad)
& $Py -I $Check compare --a (Join-Path $Run 'mutated.yuv') --b (Join-Path $Run 'dec_ff.yuv') --w 32 --h 16 --label zybo_negative
if ($LASTEXITCODE -eq 0) { throw 'negative decoder comparison incorrectly passed' }
# Corrupt the actual slice NAL header into reserved type 0 with forbidden_zero_bit
# set. JM explicitly rejects this bit instead of searching indefinitely for VCL.
# Every decoder must
# reject it or produce bytes that fail comparison; a timeout is still a failure.
$Broken=[System.IO.File]::ReadAllBytes((Join-Path $Run 'stream.264'))
$Found=$false
for($i=0;$i -lt $Broken.Length-4;$i++) {
    if($Broken[$i] -eq 0 -and $Broken[$i+1] -eq 0 -and $Broken[$i+2] -eq 0 -and $Broken[$i+3] -eq 1 -and
        (($Broken[$i+4] -band 31) -eq 5 -or ($Broken[$i+4] -band 31) -eq 1)) {
        $Broken[$i+4]=($Broken[$i+4] -band 96) -bor 128
        $Found=$true
        break
    }
}
if(-not $Found){throw 'negative control found no slice NAL'}
[System.IO.File]::WriteAllBytes((Join-Path $Run 'broken.264'),$Broken)
function NegativeDecode([string]$Name,[string]$Exe,[string[]]$Arguments) {
    $Output=Join-Path $Run "neg_$Name.yuv"
    if(Test-Path -LiteralPath $Output){[System.IO.File]::Delete($Output)}
    $Process=Start-Process -FilePath $Exe -ArgumentList $Arguments -WorkingDirectory $Run -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $Run "neg_$Name.log") -RedirectStandardError (Join-Path $Run "neg_$Name.err") -PassThru
    $null=$Process.Handle
    if(-not $Process.WaitForExit(60000)){$Process.Kill();throw "negative $Name timed out"}
    if($Process.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $Output) -or (Get-Item -LiteralPath $Output).Length -eq 0) {
        Write-Output "RTLNET_DECODER_NEG: PASS $Name rejects damaged slice"
        return
    }
    & $Py -I $Check compare --a (Join-Path $Run 'rebuilt0.yuv') --b $Output --w 32 --h 16 --label "zybo_streamneg_$Name"
    if($LASTEXITCODE -eq 0){throw "negative $Name accepted the damaged stream with matching pixels"}
    Write-Output "RTLNET_DECODER_NEG: PASS $Name damaged stream fails pixel comparison"
}
NegativeDecode 'jm' $Jm @('-i','broken.264','-o','neg_jm.yuv')
NegativeDecode 'oh' $Oh @('broken.264','neg_oh.yuv')
NegativeDecode 'ff' $Ff.Ffmpeg @('-y','-v','error','-i','broken.264','-f','rawvideo','-pix_fmt','yuv420p','neg_ff.yuv')
Write-Output 'TEST PASS: rtlnet_zybo_decoder three decoders match rebuilt pixels; negative comparison fails'
