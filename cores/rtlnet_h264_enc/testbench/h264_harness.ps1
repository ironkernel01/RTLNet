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
  * Burst monitor: the bench prints HIST (beat-count histogram per master and kind) and SUMMARY lines; the harness echoes them.
    -InjectBurst is the monitor's negative control: the bench shows its monitor one single-beat rebuilt-picture AW and must
    fail with the monitor's message (`TEST PASS: rtlnet_h264_top_<config>_burstneg`).
  * Work directories: .sim/h264/<config>/ (gitignored).
  * Macroblock mode: with the intra 16x16 encoder (register MB_MODE present in rtlnet_h264_enc_regs.sv) the rebuilt picture is lossy:
    h264_check.py prints PSNR per picture and BITS per picture and enforces the floor of the (pattern, QP) pair from
    h264_psnr_floors.txt. -Measure prints candidate floor lines (also appended to .sim/h264/floors_measured.txt) instead of
    failing on a missing floor. -Pcm selects the I_PCM macroblock mode (bench define TB_PCM=1 writes MB_MODE = 1); the rebuilt
    picture must then equal the generator's 4:2:0 reference exactly. An RTL without the MB_MODE register (the I_PCM-only
    encoder) runs the I_PCM checks automatically, with a NOTE line.
  * Configurations: <size>_e<engines>_s<slices>_q<QP> for 720p and 1080p (slices of the whole picture; e1_s2 is one engine
    with two slices), qcif_<pattern>_q<QP> for QCIF, and the named QCIF structure checks (qcif_s1, qcif_s3, qcif_ring, qcif_e2_*,
    qcif_2pic, ... at QP 28). -Config takes names or wildcards (qcif_*_q0, 720p_e2_*).
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_harness.ps1 [-Config qcif_s1,720p_*] [-Inject] [-InjectBurst] [-Pcm] [-Measure] [-Threads N] [-Gap pct] [-Lat clocks]
  -Gap and -Lat set the memory model's ready/valid gap percentage (default 20) and read latency in clocks (default 20; rtlnet_ddr_sim: gap 0, latency 20).
  Without -Config every configuration of the default set runs (several minutes per ten configurations: each one builds the bench).
Revision: 11-09-2026
  * 11-09-2026: initial version; QP/pattern configuration table, PSNR floors, bits per picture, -Pcm and -Measure.
-------------------------------------------------------------------------------
#>
param(
    [string[]]$Config = @(),
    [switch]$Inject,
    [switch]$InjectBurst,
    [switch]$Pcm,
    [switch]$Measure,
    [int]$Threads = 1,
    [switch]$NoPng,
    [int]$Gap = 20,
    [int]$Lat = 20
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

# Configuration table. Fields: Name, W/H coded size, DH display height, E engines, S slices (whole picture), P pictures,
# Pat patterns (per picture), Qp slice QP, Ring KiB, Delay (consumer clocks), Mem log2 (16-byte words).
$Configs = @()
function Add-Cfg([string]$name, [int]$w, [int]$h, [int]$dh, [int]$e, [int]$s, [int]$p, [string[]]$pat, [int]$qp, [hashtable]$extra = @{}) {
    $ring = 256; $mem = 17
    if ($w -eq 1280) { $ring = 2048; $mem = 20 }
    if ($w -eq 1920) { $ring = 4096; $mem = 20 }
    $c = @{ Name = $name; W = $w; H = $h; DH = $dh; E = $e; S = $s; P = $p; Pat = $pat; Qp = $qp; Ring = $ring; Delay = 0; Mem = $mem }
    foreach ($k in $extra.Keys) { $c[$k] = $extra[$k] }
    $script:Configs += ,$c
}
# Named QCIF structure checks (QP 28): slices, engines, two pictures, small ring with a slow consumer.
Add-Cfg 'qcif_s1'      176 144 144 1 1 1 @('noise') 28
Add-Cfg 'qcif_s3'      176 144 144 1 3 1 @('gradient') 28
Add-Cfg 'qcif_bars'    176 144 144 1 1 1 @('bars') 28
Add-Cfg 'qcif_2pic'    176 144 144 1 3 2 @('bars', 'square') 28
Add-Cfg 'qcif_zeros'   176 144 144 1 1 1 @('zeros') 28
Add-Cfg 'qcif_ring'    176 144 144 1 3 1 @('noise') 28 @{ Ring = 16; Delay = 30000; Stall = 1 }
Add-Cfg 'qcif_e2_s2'   176 144 144 2 2 1 @('gradient') 28
Add-Cfg 'qcif_e2_s4'   176 144 144 2 4 1 @('noise') 28
Add-Cfg 'qcif_e2_2pic' 176 144 144 2 2 2 @('bars', 'square') 28
# Widths that are not a multiple of the 4-macroblock read strip (the last strip of a row has fewer macroblocks: 13 = 3 x 4 + 1,
# 5 = 4 + 1, 18 = 4 x 4 + 2): bursts of 2 beats (one macroblock row) and 4 beats at the end of a row, one and two engines.
Add-Cfg 'strip_w13_s1'    208 144 144 1 1 1 @('photo') 28
Add-Cfg 'strip_w5_e2_s2'   80 144 144 2 2 1 @('gradnoise') 28
Add-Cfg 'strip_w18_s3'    288  96  96 1 3 1 @('edges') 28
# QCIF content and QP matrix.
foreach ($pq in @(
        @('photo', 0), @('photo', 18), @('photo', 28), @('photo', 38), @('photo', 51),
        @('gradnoise', 0), @('gradnoise', 18), @('gradnoise', 28), @('gradnoise', 38), @('gradnoise', 51),
        @('zoneplate', 18), @('zoneplate', 28), @('zoneplate', 38),
        @('edges', 0), @('edges', 18), @('edges', 28), @('edges', 38),
        @('checker', 0), @('checker', 18), @('checker', 28), @('checker', 38),
        @('noise', 0), @('noise', 18), @('noise', 38), @('noise', 51), @('gradient', 28), @('gradient', 51),
        @('bars', 18), @('bars', 51), @('zeros', 38))) {
    Add-Cfg ("qcif_{0}_q{1}" -f $pq[0], $pq[1]) 176 144 144 1 1 1 @($pq[0]) $pq[1]
}
# 720p and 1080p: shapes x QP, patterns rotating through the textured set so every pattern appears at both sizes.
$rot = @('photo', 'gradnoise', 'edges', 'zoneplate', 'bars', 'checker')
$ri = 0
foreach ($sz in @(@('720p', 1280, 720, 720), @('1080p', 1920, 1088, 1080))) {
    foreach ($sh in @(@(1, 1), @(1, 2), @(2, 2), @(2, 4))) {
        foreach ($qp in @(18, 28, 38, 51)) {
            $pat = $rot[$ri % $rot.Count]; $ri++
            Add-Cfg ("{0}_e{1}_s{2}_q{3}" -f $sz[0], $sh[0], $sh[1], $qp) $sz[1] $sz[2] $sz[3] $sh[0] $sh[1] 1 @($pat) $qp
        }
    }
}
$Config = @($Config | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
if ($Config.Count -gt 0) {
    $Configs = @($Configs | Where-Object { $n = $_.Name; @($Config | Where-Object { $n -like $_ }).Count -gt 0 })
}
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
# The MinGW runtime next to the host gcc is on PATH for the tool builds and for the OpenH264 decoder (built with that gcc).
$env:PATH = "$(Split-Path -Parent $Cc);$env:PATH"
$ToolDir = Get-RtlnetToolDir 'h264_enc'
$SpsTool = "$ToolDir/h264_spspps_tool.exe"
$srcNewest = (Get-ChildItem "$Repo/cores/rtlnet_h264_enc/driver/*", "$Tb/h264_spspps_tool.c" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
if (-not (Test-Path -LiteralPath $SpsTool) -or ((Get-Item -LiteralPath $SpsTool).LastWriteTime -lt $srcNewest)) {
    & $Cc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST "-I$Repo/cores/rtlnet_common/driver" "-I$Repo/cores/rtlnet_h264_enc/driver" `
        "$Repo/cores/rtlnet_h264_enc/driver/rtlnet_h264_enc.c" "$Tb/h264_spspps_tool.c" -o $SpsTool
    if ($LASTEXITCODE -ne 0) { throw 'h264_spspps_tool build failed' }
}

# MB_MODE register present in the RTL? Without it the encoder is the I_PCM-only one: I_PCM checks run automatically.
$HasMbMode = (Select-String -Path "$Repo/cores/rtlnet_h264_enc/hdl/rtlnet_h264_enc_regs.sv" -Pattern 'MB_MODE' -Quiet)
$PcmChecks = $Pcm.IsPresent -or (-not $HasMbMode)
if (-not $HasMbMode) { Write-Output 'NOTE: RTL has no MB_MODE register (I_PCM-only encoder): running the I_PCM checks (exact rebuilt picture, no PSNR floors)' }
$Floors = "$Tb/h264_psnr_floors.txt"
$Measured = "$Sim/floors_measured.txt"

$allOk = $true
foreach ($c in $Configs) {
    $name = $c.Name
    $label = if ($InjectBurst) { "${name}_burstneg" } elseif ($Inject) { "${name}_neg" } else { $name }
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
              "TB_CONSUMER_DELAY=$($c.Delay)", "TB_MEM_LOG2=$($c.Mem)", "TB_GAP=$Gap", "TB_LAT=$Lat", "TB_QP=$($c.Qp)")
    if ($Pcm -and $HasMbMode) { $defs += 'TB_PCM=1' }
    if ($c.ContainsKey('Stall')) { $defs += 'TB_EXPECT_STALL=1' }
    $fdir = $dir.Replace([string][char]92, '/')
    $pa = @("IN0=$fdir/in0.hex", "OUT=$fdir/o")
    if ($c.P -gt 1) { $pa += "IN1=$fdir/in1.hex" }
    if ($Inject) { $pa += 'INJECT' }
    if ($InjectBurst) { $pa += 'INJECT_BURST' }
    $simOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Repo/scripts/rtlnet_run_verilator.ps1" -Bench tb_rtlnet_h264_top `
        -Filelist cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_top.f -Tag $label -Defines ($defs -join ',') -PlusArgs ($pa -join ',') -Threads $Threads
    $simLine = ($simOut | Select-Object -Last 1)
    $simSecs = $sw.Elapsed.TotalSeconds
    Write-Output "[$label] bench: $simLine"
    $runLog = Read-Text "$Repo/.sim/verilator/tb_rtlnet_h264_top_$label/run.log"
    if ($InjectBurst) {
        if (($LASTEXITCODE -ne 0) -and ($runLog -match 'burst monitor: engine 0 single-beat rebuilt-picture AW')) {
            Write-Output "TEST PASS: rtlnet_h264_top_$label (negative control: the burst monitor fired on the injected single-beat AW)"
        } else {
            Write-Output "TEST FAIL: rtlnet_h264_top_$label (negative control: the burst monitor did not fire)"; $allOk = $false
        }
        continue
    }
    if ($LASTEXITCODE -ne 0) { $fails += 'bench'; $allOk = $false; Write-Output "TEST FAIL: rtlnet_h264_top_$label (bench)"; continue }
    foreach ($m in [regex]::Matches($runLog, '(?m)^(STAT|HIST|SUMMARY) [^\r\n]*')) { Write-Output "[$label] $($m.Value)" }

    # Assemble stream and rebuilt YUV; rebuilt must equal the reference.
    $asmExtra = @('--pattern', ($c.Pat -join ','), '--qp', "$($c.Qp)", '--floors', $Floors)
    if ($PcmChecks) { $asmExtra += '--pcm' }
    if ($Measure -or $Inject) { $asmExtra += '--measure' }
    $asm = & $Py -I "$Tb/h264_check.py" assemble --dir $dir --prefix "$dir/o" --spspps "$dir/sps.bin" --pics $c.P --disp-h $c.DH --refs @refs @asmExtra
    $asm | ForEach-Object {
        Write-Output "[$label] $_"
        if ($Measure -and ($_ -match '^FLOOR \S+ \d+ [\d.]+$')) { [System.IO.File]::AppendAllText($Measured, "$_`n") }
    }
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
