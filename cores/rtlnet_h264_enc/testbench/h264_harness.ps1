<#
-------------------------------------------------------------------------------
File: h264_harness.ps1
Purpose: the decoder-checked verification run of rtlnet_h264_top (documentation/gige.md section 13): input image,
  encode in the Verilator bench, Annex B stream, three independent decoders, byte comparison, PNGs.
Overview:
  * Per configuration (see $Configs): h264_gen.py writes the input frame(s) and their 4:2:0 reference; the driver's
    SPS/PPS writer (h264_spspps_tool, built here with the host gcc) writes the stream parameter sets; the bench
    tb_rtlnet_h264_top runs in Verilator (scripts/rtlnet_run_verilator.ps1) and dumps the Annex B stream and
    the rebuilt planes; h264_check.py assembles stream.264 (SPS + PPS + stream) and the rebuilt YUV.
  * Decoders: JM ldecod, OpenH264 h264dec (both built by h264_build_decoders.ps1) and FFmpeg
    (-f rawvideo -pix_fmt yuv420p). A decoder passes when it exits with code 0, prints no error, and its YUV is
    byte-identical to the rebuilt YUV. For I_PCM the rebuilt YUV must also equal the generator's reference (PSNR inf).
    On a mismatch the first differing macroblock (x, y, plane) is printed.
  * Prints `TEST PASS: rtlnet_h264_top_<config>` per configuration. -Inject runs the negative control: the bench
    corrupts one PCM byte of the stream after the rebuilt picture is written; the configuration passes
    (`TEST PASS: rtlnet_h264_top_<config>_neg`) only when all three decoder comparisons fail.
  * PNGs per configuration in <work>/png: src_<n>.png (generator reference), jm_<n>.png, oh_<n>.png, ff_<n>.png and
    side_<n>.png (source, JM, OpenH264, FFmpeg side by side).
  * Work directories: .sim/h264/<config>/ (gitignored).
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_harness.ps1 [-Config qcif_s1,720p_s1] [-Inject] [-Threads N]
  Without -Config every configuration of the default set runs ('1080p_s1' and '1080p_s4' included).
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
param(
    [string[]]$Config = @(),
    [switch]$Inject,
    [int]$Threads = 1,
    [switch]$NoPng
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Py    = Resolve-RtlnetPython
$Cc    = Resolve-RtlnetHostCc
$Ff    = Resolve-RtlnetFfmpeg
$Ldec  = Resolve-RtlnetLdecod
$H264d = Resolve-RtlnetH264dec
if (-not $Ldec -or -not $H264d) { throw 'decoders not built: run cores/rtlnet_h264_enc/testbench/h264_build_decoders.ps1' }
$Tb    = Join-Path $Repo 'cores/rtlnet_h264_enc/testbench'
$Sim   = Join-Path $Repo '.sim/h264'
New-Item -ItemType Directory -Force -Path $Sim | Out-Null

# name, coded w, coded h, display h, slices, pics, pattern 0, pattern 1 (or square frame 1), ring KB, consumer delay, memory log2 (16-byte words)
$Configs = @(
    @{ Name = 'qcif_s1';     W = 176;  H = 144;  DH = 144;  E = 1; S = 1; P = 1; Pat = @('noise');          Ring = 256;  Delay = 0;     Mem = 17 },
    @{ Name = 'qcif_s3';     W = 176;  H = 144;  DH = 144;  E = 1; S = 3; P = 1; Pat = @('gradient');       Ring = 256;  Delay = 0;     Mem = 17 },
    @{ Name = 'qcif_bars';   W = 176;  H = 144;  DH = 144;  E = 1; S = 1; P = 1; Pat = @('bars');           Ring = 256;  Delay = 0;     Mem = 17 },
    @{ Name = 'qcif_2pic';   W = 176;  H = 144;  DH = 144;  E = 1; S = 3; P = 2; Pat = @('bars', 'square'); Ring = 256;  Delay = 0;     Mem = 17 },
    @{ Name = 'qcif_zeros';  W = 176;  H = 144;  DH = 144;  E = 1; S = 1; P = 1; Pat = @('zeros');          Ring = 256;  Delay = 0;     Mem = 17 },
    @{ Name = 'qcif_ring';   W = 176;  H = 144;  DH = 144;  E = 1; S = 3; P = 1; Pat = @('noise');          Ring = 24;   Delay = 30000; Mem = 17; Stall = 1 },
    @{ Name = 'qcif_e2_s2';  W = 176;  H = 144;  DH = 144;  E = 2; S = 2; P = 1; Pat = @('gradient');       Ring = 256;  Delay = 0;     Mem = 17 },
    @{ Name = 'qcif_e2_s4';  W = 176;  H = 144;  DH = 144;  E = 2; S = 4; P = 1; Pat = @('noise');          Ring = 256;  Delay = 0;     Mem = 17 },
    @{ Name = 'qcif_e2_2pic'; W = 176; H = 144;  DH = 144;  E = 2; S = 2; P = 2; Pat = @('bars', 'square'); Ring = 256;  Delay = 0;     Mem = 17 },
    @{ Name = '720p_e1_s1';  W = 1280; H = 720;  DH = 720;  E = 1; S = 1; P = 1; Pat = @('gradient');       Ring = 2048; Delay = 0;     Mem = 20 },
    @{ Name = '720p_e2_s2';  W = 1280; H = 720;  DH = 720;  E = 2; S = 2; P = 1; Pat = @('gradient');       Ring = 2048; Delay = 0;     Mem = 20 },
    @{ Name = '720p_e2_s4';  W = 1280; H = 720;  DH = 720;  E = 2; S = 4; P = 1; Pat = @('bars');           Ring = 2048; Delay = 0;     Mem = 20 },
    @{ Name = '1080p_e1_s1'; W = 1920; H = 1088; DH = 1080; E = 1; S = 1; P = 1; Pat = @('bars');           Ring = 4096; Delay = 0;     Mem = 20 },
    @{ Name = '1080p_e2_s2'; W = 1920; H = 1088; DH = 1080; E = 2; S = 2; P = 1; Pat = @('gradient');       Ring = 4096; Delay = 0;     Mem = 20 },
    @{ Name = '1080p_e2_s4'; W = 1920; H = 1088; DH = 1080; E = 2; S = 4; P = 1; Pat = @('bars');           Ring = 4096; Delay = 0;     Mem = 20 }
)
$Config = @($Config | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
if ($Config.Count -gt 0) { $Configs = @($Configs | Where-Object { $Config -contains $_.Name }) }
if ($Configs.Count -eq 0) { throw 'no matching configuration' }

function Invoke-Tool([string]$exe, [string[]]$toolArgs, [string]$workDir, [string]$outFile) {
    $err = "$outFile.err"
    $p = Start-Process -FilePath $exe -ArgumentList $toolArgs -WorkingDirectory $workDir -NoNewWindow -PassThru `
         -RedirectStandardOutput $outFile -RedirectStandardError $err
    $null = $p.Handle
    $p.WaitForExit()
    return $p.ExitCode
}
function Read-Text([string]$path) {
    if (Test-Path -LiteralPath $path) { return [System.IO.File]::ReadAllText($path) }
    return ''
}

# SPS/PPS tool, built from the driver with the host gcc.
$ToolDir = Get-RtlnetToolDir 'h264_enc'
$SpsTool = "$ToolDir/h264_spspps_tool.exe"
$srcNewest = (Get-ChildItem "$Repo/cores/rtlnet_h264_enc/driver/*", "$Tb/h264_spspps_tool.c" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
if (-not (Test-Path -LiteralPath $SpsTool) -or ((Get-Item -LiteralPath $SpsTool).LastWriteTime -lt $srcNewest)) {
    $env:PATH = "$(Split-Path -Parent $Cc);$env:PATH"
    & $Cc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST "-I$Repo/cores/rtlnet_common/driver" "-I$Repo/cores/rtlnet_h264_enc/driver" `
        "$Repo/cores/rtlnet_h264_enc/driver/rtlnet_h264_enc.c" "$Tb/h264_spspps_tool.c" -o $SpsTool
    if ($LASTEXITCODE -ne 0) { throw 'h264_spspps_tool build failed' }
}

$allOk = $true
foreach ($c in $Configs) {
    $name = $c.Name
    $label = if ($Inject) { "${name}_neg" } else { $name }
    $dir = "$Sim/$label"
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir, "$dir/png" | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $fails = @()

    # Input frames and references.
    $refs = @()
    for ($n = 0; $n -lt $c.P; $n++) {
        $pat = $c.Pat[[Math]::Min($n, $c.Pat.Count - 1)]
        $frame = 0
        if ($pat -eq 'square') { $frame = 1 }
        & $Py -I "$Tb/h264_gen.py" --pattern $pat --w $c.W --h $c.H --frame $frame --seed (7 + $n) --out "$dir/in$n" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "h264_gen.py failed for $name" }
        $refs += "$dir/in${n}_ref.yuv"
    }

    # Stream parameter sets from the driver.
    $toolArgs = @("$($c.W)", "$($c.H)", "$($c.W)", "$($c.DH)", '30', '4', "$dir/sps.bin")
    if ($c.W -eq 1280) { $toolArgs = @('mode', '0', '4', "$dir/sps.bin") }
    if ($c.W -eq 1920) { $toolArgs = @('mode', '1', '4', "$dir/sps.bin") }
    $rc = Invoke-Tool $SpsTool $toolArgs $dir "$dir/sps_tool.log"
    if ($rc -ne 0) { throw "SPS/PPS tool failed: $(Read-Text "$dir/sps_tool.log.err")" }

    # Encode in Verilator.
    $defs = @("TB_MBW=$($c.W / 16)", "TB_MBH=$($c.H / 16)", "TB_SLICES=$($c.S)", "TB_ENGINES=$($c.E)", "TB_PICS=$($c.P)", "TB_RING_KB=$($c.Ring)",
              "TB_CONSUMER_DELAY=$($c.Delay)", "TB_MEM_LOG2=$($c.Mem)", 'TB_GAP=20', 'TB_LAT=20')
    if ($c.ContainsKey('Stall')) { $defs += 'TB_EXPECT_STALL=1' }
    $fdir = $dir.Replace([string][char]92, '/')
    $pa = @("IN0=$fdir/in0.hex", "OUT=$fdir/o")
    if ($c.P -gt 1) { $pa += "IN1=$fdir/in1.hex" }
    if ($Inject) { $pa += 'INJECT' }
    $simOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Repo/scripts/rtlnet_run_verilator.ps1" -Bench tb_rtlnet_h264_top `
        -Filelist cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_top.f -Tag $label -Defines ($defs -join ',') -PlusArgs ($pa -join ',') -Threads $Threads
    $simLine = ($simOut | Select-Object -Last 1)
    $simSecs = $sw.Elapsed.TotalSeconds
    Write-Output "[$label] bench: $simLine"
    if ($LASTEXITCODE -ne 0) { $fails += 'bench'; $allOk = $false; Write-Output "TEST FAIL: rtlnet_h264_top_$label (bench)"; continue }
    $runLog = Read-Text "$Repo/.sim/verilator/tb_rtlnet_h264_top_$label/run.log"
    foreach ($m in [regex]::Matches($runLog, '(?m)^STAT [^\r\n]*')) { Write-Output "[$label] $($m.Value)" }

    # Assemble stream and rebuilt YUV; rebuilt must equal the reference.
    $asm = & $Py -I "$Tb/h264_check.py" assemble --dir $dir --prefix "$dir/o" --spspps "$dir/sps.bin" --pics $c.P --disp-h $c.DH --refs @refs
    $asm | ForEach-Object { Write-Output "[$label] $_" }
    if ($LASTEXITCODE -ne 0) { $fails += 'rebuilt vs reference' }

    # Decode with the three decoders and compare each to the rebuilt YUV.
    $frameBytes = $c.W * $c.DH * 3 / 2
    $decRes = @{}
    $rc = Invoke-Tool $Ldec @('-i', 'stream.264', '-o', 'dec_jm.yuv') $dir "$dir/jm.log"
    $jmText = (Read-Text "$dir/jm.log") + (Read-Text "$dir/jm.log.err") + (Read-Text "$dir/log.dec")
    $jmErr = ($rc -ne 0) -or ($jmText -match '(?im)\berror\b') -or ($jmText -notmatch "$($c.P) frames are decoded")
    $decRes['jm'] = @{ Err = $jmErr; Detail = "rc=$rc" }
    $rc = Invoke-Tool $H264d @('stream.264', 'dec_oh.yuv') $dir "$dir/oh.log"
    $ohText = (Read-Text "$dir/oh.log") + (Read-Text "$dir/oh.log.err")
    $ohErr = ($rc -ne 0) -or ($ohText -match '(?im)(\berror\b|fail)') -or ($ohText -notmatch "Frames:\s+$($c.P)\b")
    $decRes['oh'] = @{ Err = $ohErr; Detail = "rc=$rc" }
    $rc = Invoke-Tool $Ff.Ffmpeg @('-y', '-v', 'error', '-i', 'stream.264', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', 'dec_ff.yuv') $dir "$dir/ff.log"
    $ffText = (Read-Text "$dir/ff.log") + (Read-Text "$dir/ff.log.err")
    $ffErr = ($rc -ne 0) -or ($ffText.Trim().Length -gt 0)
    $decRes['ff'] = @{ Err = $ffErr; Detail = "rc=$rc" }

    $probe = & $Ff.Ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$dir/stream.264"
    $expectSize = "$($c.W),$($c.DH)"
    Write-Output "[$label] ffprobe size: $probe (expected $expectSize)"
    if ($probe -ne $expectSize) { $fails += 'display size' }
    $ohSize = [regex]::Match($ohText, 'iWidth:\s+(\d+)\s+height:\s+(\d+)')
    Write-Output "[$label] OpenH264 size: $($ohSize.Groups[1].Value)x$($ohSize.Groups[2].Value)"
    $verVersions = ''
    foreach ($d in 'jm', 'oh', 'ff') {
        $cmp = @()
        $okAll = $true
        for ($n = 0; $n -lt $c.P; $n++) {
            # Compare frame n of the decoded file with rebuilt n.
            $decFile = "$dir/dec_$d.yuv"
            $one = "$dir/dec_${d}_$n.yuv"
            if (Test-Path -LiteralPath $decFile) {
                $bytes = [System.IO.File]::ReadAllBytes($decFile)
                if ($bytes.Length -ge (($n + 1) * $frameBytes)) {
                    $fs = [System.IO.File]::Create($one)
                    $fs.Write($bytes, $n * $frameBytes, $frameBytes); $fs.Close()
                } else { [System.IO.File]::WriteAllBytes($one, [byte[]]@()) }
            } else { [System.IO.File]::WriteAllBytes($one, [byte[]]@()) }
            $out = & $Py -I "$Tb/h264_check.py" compare --a "$dir/rebuilt$n.yuv" --b $one --w $c.W --h $c.DH --label "${d}_pic$n"
            $out | ForEach-Object { Write-Output "[$label] $_" }
            if ($LASTEXITCODE -ne 0) { $okAll = $false }
        }
        $decRes[$d].Match = $okAll
        $err = $decRes[$d].Err
        Write-Output ("[{0}] decoder {1}: errors={2} {3} match={4}" -f $label, $d, $err, $decRes[$d].Detail, $okAll)
    }

    # PNGs (frame n of the source reference and of each decoder, then a side-by-side).
    if (-not $NoPng) {
        for ($n = 0; $n -lt $c.P; $n++) {
            $png = @{}
            foreach ($t in @(@('src', "$dir/ref$n.yuv"), @('jm', "$dir/dec_jm_$n.yuv"), @('oh', "$dir/dec_oh_$n.yuv"), @('ff', "$dir/dec_ff_$n.yuv"))) {
                $outp = "$dir/png/$($t[0])_$n.png"
                if ((Test-Path -LiteralPath $t[1]) -and ((Get-Item -LiteralPath $t[1]).Length -gt 0)) {
                    $null = Invoke-Tool $Ff.Ffmpeg @('-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-s', "$($c.W)x$($c.DH)", '-i', $t[1], '-frames:v', '1', $outp) $dir "$dir/png/ff_$($t[0])_$n.log"
                    $png[$t[0]] = $outp
                }
            }
            if ($png.Count -eq 4) {
                $null = Invoke-Tool $Ff.Ffmpeg @('-y', '-v', 'error', '-i', $png['src'], '-i', $png['jm'], '-i', $png['oh'], '-i', $png['ff'],
                    '-filter_complex', '[0][1][2][3]hstack=inputs=4', "$dir/png/side_$n.png") $dir "$dir/png/ff_side_$n.log"
            }
        }
    }

    # Verdict.
    if ($Inject) {
        $allFail = $true
        foreach ($d in 'jm', 'oh', 'ff') { if ($decRes[$d].Match -and -not $decRes[$d].Err) { $allFail = $false } }
        if ($allFail) { Write-Output "TEST PASS: rtlnet_h264_top_$label (negative control: all three decoder comparisons failed, $([int]$sw.Elapsed.TotalSeconds) s)" }
        else { Write-Output "TEST FAIL: rtlnet_h264_top_$label (negative control: a decoder comparison still passed)"; $allOk = $false }
    } else {
        foreach ($d in 'jm', 'oh', 'ff') {
            if ($decRes[$d].Err -or -not $decRes[$d].Match) { $fails += "decoder $d" }
        }
        if ($fails.Count -eq 0) { Write-Output "TEST PASS: rtlnet_h264_top_$label (JM, OpenH264, FFmpeg identical to the rebuilt picture, $([int]$sw.Elapsed.TotalSeconds) s total, bench $([int]$simSecs) s)" }
        else { Write-Output "TEST FAIL: rtlnet_h264_top_$label ($($fails -join ', '))"; $allOk = $false }
    }
}
if (-not $allOk) { exit 1 }
exit 0
