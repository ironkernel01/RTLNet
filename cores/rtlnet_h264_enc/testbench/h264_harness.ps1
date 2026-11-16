<#
-------------------------------------------------------------------------------
File: h264_harness.ps1
Purpose: the decoder-checked verification run of rtlnet_h264_top: input image,
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
  * P pictures (phase 2c-1): configurations named p_* run a GOP (Gop: a string of I and P, one letter per picture; an I picture is an
    IDR picture) of a generated sequence (Seq: static, pan, bars_move, noise_p, cut; h264_gen.py --seq). The bench keeps the two
    rebuilt buffers in the memory model across the pictures, and EVERY picture is checked: JM, OpenH264 and FFmpeg must decode
    it byte-identical to the de-tiled rebuilt picture of that picture, and the PSNR floor of (sequence, QP) must hold for each
    picture (h264_psnr_floors.txt; -Measure prints the candidate line, the minimum over the pictures minus 1 dB). A configuration
    with AllSkip (the static scene) must code every P picture as skipped macroblocks only. The p_* configurations run only when
    named with -Config (-Config p_*); without -Config the earlier set runs. -InjectBurstRef is the negative control of the
    monitor's reference-read check (a 4-beat reference read; the bench must fail). -BuildToolsOnly builds the SPS/PPS tool and exits;
    -ListConfigs prints the names of the selected configurations (h264_harness_par.ps1 runs them in parallel).
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_harness.ps1 [-Config qcif_s1,720p_*] [-Inject] [-InjectBurst] [-InjectBurstRef] [-Pcm] [-Irq] [-Measure] [-Threads N] [-Gap pct] [-Lat clocks]
  -Gap and -Lat set the memory model's ready/valid gap percentage (default 20) and read latency in clocks (default 20; rtlnet_ddr_sim: gap 0, latency 20).
  Without -Config every configuration of the default set runs (several minutes per ten configurations: each one builds the bench).
  * Motion search (phase 2c-2): configurations named m_* run the panning sequences panh<k> / panv<k> / pand<k> (the window moves k samples per
    picture), pan<k> beyond the range, bounce and objs; a configuration with ExpMv = (x, y) passes +EXPMV_X / +EXPMV_Y to the bench, which prints
    `MVSTAT pic<n> interior=<I> true=<T>` per P picture (macroblocks whose block at the expected vector lies inside the picture, and those among
    them coded as inter with exactly that vector), and the harness requires T >= 90 % of I for every P picture. Sr = n sets the core's search
    range (TB_SR; Sr 0 is the phase 2c-1 behaviour, the baseline of the bits gate, see h264_check.py bitsratio).
  * -AxiW 64 (11-15-2026): the core and the memory model run with 64-bit memory ports (bench define TB_AXI_W=64, label suffix _w64). Each configuration is
    run a second time with 128-bit ports (the bench only, label <label>_ref128) and must leave the same memory: the bench prints MEMHASH, a hash of
    every word of the memory model after the run, and the two values must be equal (the same bytes for the input frame area, the compressed ring, the
    index ring and both rebuilt pictures), before the decoders compare the stream. -InjectWidth is the negative control of that comparison (the
    bench flips one bit of one memory word before the hash; the run must report the mismatch).
Revision: 11-15-2026
  * 11-15-2026: -AxiW, -InjectWidth.
  * 11-13-2026: the SPS/PPS tool start is tried again (the tool folder is shared by every checkout on the machine).
  * 11-12-2026: -Irq: the bench takes the picture end from the irq output (IRQ_ENABLE, CTRL.IRQ_EN) instead of polling STATUS; the streams must be byte-identical to the polled run.
  * 11-09-2026: initial version; QP/pattern configuration table, PSNR floors, bits per picture, -Pcm and -Measure.
  * 11-10-2026: phase 2c-1: GOP and sequence configurations (p_*), one input buffer reloaded per picture, -InjectBurstRef.
  * 11-10-2026: phase 2c-2: m_* motion configurations, ExpMv and Sr.
-------------------------------------------------------------------------------
#>
param(
    [string[]]$Config = @(),
    [switch]$Inject,
    [switch]$InjectBurst,
    [switch]$InjectBurstRef,
    [switch]$BuildToolsOnly,
    [switch]$ListConfigs,
    [switch]$Pcm,
    [switch]$Irq,
    [string]$DbkCtl = '',
    [switch]$NoDbk,
    [string]$Tag = '',
    [switch]$Measure,
    [int]$Threads = 1,
    [switch]$NoPng,
    [int]$Gap = 20,
    [int]$Lat = 20,
    [ValidateSet(128, 64)][int]$AxiW = 128,
    [switch]$InjectWidth
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
    $c = @{ Name = $name; W = $w; H = $h; DH = $dh; E = $e; S = $s; P = $p; Pat = $pat; Qp = $qp; Ring = $ring; Delay = 0; Mem = $mem; Gop = ('I' * $p); Seq = ''; AllSkip = $false; Group = 'i' }
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
# P-picture configurations (phase 2c-1): a GOP of a generated sequence, every picture checked. QCIF structure and content set, then 720p
# and 1080p on 1 and 2 engines with 1, 2 and 4 slices over QP 12 to 51.
function Add-PCfg([string]$name, [int]$w, [int]$h, [int]$dh, [int]$e, [int]$s, [string]$gop, [string]$seq, [int]$qp, [hashtable]$extra = @{}) {
    $x = @{ Gop = $gop; Seq = $seq; Group = 'p' }
    foreach ($k in $extra.Keys) { $x[$k] = $extra[$k] }
    Add-Cfg $name $w $h $dh $e $s $gop.Length @($seq) $qp $x
}
$g9  = 'IPPPPPPPP'
$g10 = 'IPPPPIPPPP'
$gc  = 'IPPPPPPPPP'   # the scene cut (picture 5) is inside a P run: the cut picture is coded as P
# QCIF: sequences x QP (static = all-skip).
foreach ($q in @(12, 28, 38, 51)) { Add-PCfg "p_qcif_static_q$q" 176 144 144 1 1 $g9 'static' $q @{ AllSkip = $true } }
foreach ($q in @(12, 20, 28, 38, 51)) { Add-PCfg "p_qcif_pan_q$q" 176 144 144 1 1 $g10 'pan' $q }
foreach ($q in @(12, 28, 51)) { Add-PCfg "p_qcif_bars_q$q" 176 144 144 1 1 $g9 'bars_move' $q }
foreach ($q in @(12, 28, 51)) { Add-PCfg "p_qcif_noise_q$q" 176 144 144 1 1 $g9 'noise_p' $q }
foreach ($q in @(12, 28, 38, 51)) { Add-PCfg "p_qcif_cut_q$q" 176 144 144 1 1 $gc 'cut' $q }
# QCIF structure: slices (skip runs crossing slice boundaries reset), engines, a long GOP (frame_num wraps at 16), widths that are not a
# multiple of the 4-macroblock strip, a small ring with a slow consumer.
Add-PCfg 'p_qcif_pan_s3_q28'      176 144 144 1 3 $g10 'pan' 28
Add-PCfg 'p_qcif_static_s3_q28'   176 144 144 1 3 $g9 'static' 28 @{ AllSkip = $true }
Add-PCfg 'p_qcif_cut_s9_q28'      176 144 144 1 9 $gc 'cut' 28
Add-PCfg 'p_qcif_pan_e2_s2_q28'   176 144 144 2 2 $g10 'pan' 28
Add-PCfg 'p_qcif_cut_e2_s4_q38'   176 144 144 2 4 $gc 'cut' 38
Add-PCfg 'p_qcif_static_e2_s2_q28' 176 144 144 2 2 $g9 'static' 28 @{ AllSkip = $true }
Add-PCfg 'p_qcif_pan_gop20_q28'   176 144 144 1 1 'IPPPPPPPPPPPPPPPPPPP' 'pan' 28
Add-PCfg 'p_strip_w13_s1_q28'     208 144 144 1 1 $g9 'pan' 28
Add-PCfg 'p_strip_w5_e2_s2_q28'    80 144 144 2 2 $g9 'bars_move' 28
Add-PCfg 'p_strip_w18_s3_q28'     288  96  96 1 3 $g9 'cut' 28
Add-PCfg 'p_qcif_ring_q28'        176 144 144 1 3 $g9 'pan' 28 @{ Ring = 16; Delay = 30000 }
# 720p and 1080p.
$pseq = @('pan', 'bars_move', 'static', 'cut', 'noise_p', 'pan')
$pqp = @(12, 28, 38, 51)
$pi = 0
foreach ($sz in @(@('720p', 1280, 720, 720), @('1080p', 1920, 1088, 1080))) {
    foreach ($sh in @(@(1, 1), @(1, 2), @(2, 2), @(2, 4))) {
        $seq = $pseq[$pi % $pseq.Count]
        $q = $pqp[$pi % $pqp.Count]
        $gop = if (($pi % 2) -eq 0) { 'IPPPPPPPP' } else { 'IPPPIPPP' }
        $pi++
        Add-PCfg ("p_{0}_e{1}_s{2}_q{3}" -f $sz[0], $sh[0], $sh[1], $q) $sz[1] $sz[2] $sz[3] $sh[0] $sh[1] $gop $seq $q @{ AllSkip = ($seq -eq 'static') }
    }
}
# Throughput configurations: 1080p, two engines, QP 28, a moving picture and a static one, 9 pictures.
Add-PCfg 'p_1080p_e2_s2_pan_q28'    1920 1088 1080 2 2 $g9 'pan' 28
Add-PCfg 'p_1080p_e2_s2_static_q28' 1920 1088 1080 2 2 $g9 'static' 28 @{ AllSkip = $true }
# Motion search configurations (phase 2c-2, m_*): pans by known integer vectors (horizontal, vertical, diagonal; magnitudes 1 to 16), a pan beyond the
# range (24), a window that bounces (content enters and leaves at every picture edge), moving objects over a static background, moving bars, noise and a
# cut, at QCIF, 720p and 1080p, on 1 and 2 engines with 1, 2 and 4 slices over QP 12 to 51. A configuration with ExpMv carries the search-quality gate
# (at least 90 % of the macroblocks whose block at the pan vector lies inside the picture carry that vector, in every P picture); it applies at QP 12 to
# 28 (above that the quantizer leaves too little of the texture for the vector to be the SAD minimum). The _sr0 configurations run the core with the
# search range 0 (the vector (0, 0) only, the phase 2c-1 behaviour): the baseline of the bits gate.
foreach ($pv in @(@('panh', 1, 0), @('panh', 2, 0), @('panh', 3, 0), @('panh', 5, 0), @('panh', 8, 0), @('panh', 12, 0), @('panh', 16, 0),
                  @('panv', 1, 0), @('panv', 4, 0), @('panv', 9, 0), @('panv', 16, 0), @('pand', 2, 0), @('pand', 6, 0), @('pand', 11, 0), @('pand', 16, 0))) {
    $k = $pv[1]
    $ex = switch ($pv[0]) { 'panh' { @($k, 0) } 'panv' { @(0, $k) } default { @($k, $k) } }
    Add-PCfg ("m_qcif_{0}{1}_q28" -f $pv[0], $k) 176 144 144 1 1 $g9 ("{0}{1}" -f $pv[0], $k) 28 @{ ExpMv = $ex }
}
Add-PCfg 'm_qcif_panh8_q12'      176 144 144 1 1 $g9  'panh8'  12 @{ ExpMv = @(8, 0) }
Add-PCfg 'm_qcif_pand6_q20'      176 144 144 1 1 $g9  'pand6'  20 @{ ExpMv = @(6, 6) }
Add-PCfg 'm_qcif_panh3_q38'      176 144 144 1 1 $g9  'panh3'  38
Add-PCfg 'm_qcif_pand11_q51'     176 144 144 1 1 $g9  'pand11' 51
Add-PCfg 'm_qcif_pan24_q28'      176 144 144 1 1 $g9  'panh24' 28
Add-PCfg 'm_qcif_pan24_q12'      176 144 144 1 1 $g9  'pand24' 12
Add-PCfg 'm_qcif_bounce_q28'     176 144 144 1 1 $g10 'bounce' 28
Add-PCfg 'm_qcif_bounce_q12'     176 144 144 1 1 $g9  'bounce' 12
Add-PCfg 'm_qcif_bounce_q51'     176 144 144 1 1 $g9  'bounce' 51
Add-PCfg 'm_qcif_objs_q28'       176 144 144 1 1 $g9  'objs'   28
Add-PCfg 'm_qcif_objs_q12'       176 144 144 1 1 $g9  'objs'   12
Add-PCfg 'm_qcif_objs_q51'       176 144 144 1 1 $g9  'objs'   51
Add-PCfg 'm_qcif_pan_q28'        176 144 144 1 1 $g10 'pan'    28
Add-PCfg 'm_qcif_bars_q28'       176 144 144 1 1 $g9  'bars_move' 28
Add-PCfg 'm_qcif_noise_q28'      176 144 144 1 1 $g9  'noise_p' 28
Add-PCfg 'm_qcif_cut_q28'        176 144 144 1 1 $gc  'cut'    28
Add-PCfg 'm_qcif_static_q28'     176 144 144 1 1 $g9  'static' 28 @{ AllSkip = $true }
Add-PCfg 'm_qcif_panh8_s3_q28'   176 144 144 1 3 $g9  'panh8'  28 @{ ExpMv = @(8, 0) }
Add-PCfg 'm_qcif_pand6_e2_s2_q28' 176 144 144 2 2 $g9 'pand6'  28
Add-PCfg 'm_qcif_panv4_e2_s4_q20' 176 144 144 2 4 $g9 'panv4'  20 @{ ExpMv = @(0, 4) }
Add-PCfg 'm_qcif_objs_e2_s2_q38' 176 144 144 2 2 $g9  'objs'   38
Add-PCfg 'm_qcif_bounce_s9_q28'  176 144 144 1 9 $g9  'bounce' 28
Add-PCfg 'm_strip_w13_panh8_q28' 208 144 144 1 1 $g9  'panh8'  28 @{ ExpMv = @(8, 0) }
Add-PCfg 'm_strip_w5_e2_pand3_q28' 80 144 144 2 2 $g9 'pand3'  28
Add-PCfg 'm_strip_w18_panv7_q28' 288  96  96 1 3 $g9  'panv7'  28 @{ ExpMv = @(0, 7) }
Add-PCfg 'm_qcif_panh8_q28_sr0'  176 144 144 1 1 $g9  'panh8'  28 @{ Sr = 0 }
Add-PCfg 'm_qcif_pand6_q28_sr0'  176 144 144 1 1 $g9  'pand6'  28 @{ Sr = 0 }
Add-PCfg 'm_qcif_pan_q28_sr0'    176 144 144 1 1 $g10 'pan'    28 @{ Sr = 0 }
Add-PCfg 'm_qcif_panh8_q28_sr8'  176 144 144 1 1 $g9  'panh8'  28 @{ Sr = 8; ExpMv = @(8, 0) }
Add-PCfg 'm_720p_e1_s1_panh8_q28'  1280  720  720 1 1 $g9 'panh8'  28 @{ ExpMv = @(8, 0) }
Add-PCfg 'm_720p_e2_s2_pand6_q38'  1280  720  720 2 2 $g9 'pand6'  38
Add-PCfg 'm_720p_e1_s2_objs_q28'   1280  720  720 1 2 $g9 'objs'   28
Add-PCfg 'm_720p_e2_s4_bounce_q12' 1280  720  720 2 4 $gc 'bounce' 12
Add-PCfg 'm_1080p_e2_s2_panh12_q28' 1920 1088 1080 2 2 $g9 'panh12' 28 @{ ExpMv = @(12, 0) }
Add-PCfg 'm_1080p_e2_s2_panh12_q28_sr0' 1920 1088 1080 2 2 $g9 'panh12' 28 @{ Sr = 0 }
Add-PCfg 'm_1080p_e1_s1_pand16_q20'  1920 1088 1080 1 1 $g9 'pand16' 20 @{ ExpMv = @(16, 16) }
Add-PCfg 'm_1080p_e2_s4_objs_q51'    1920 1088 1080 2 4 $g9 'objs'   51
Add-PCfg 'm_1080p_e2_s2_noise_q28'   1920 1088 1080 2 2 $g9 'noise_p' 28
# Deblocking filter measurements (d_*): moving sequences at 720p and 1080p on two engines, QP 28, 36 and 44, one IPP group; run once with the filter in
# force and once with -DbkCtl 0 -Tag off for the PSNR / bits / clocks tables of documentation section 19.
foreach ($q in @(28, 36, 44)) {
    foreach ($sq in @('pan', 'objs')) {
        Add-PCfg "d_720p_e2_s2_${sq}_q$q"  1280  720  720 2 2 'IPP' $sq $q
        Add-PCfg "d_1080p_e2_s2_${sq}_q$q" 1920 1088 1080 2 2 'IPP' $sq $q
    }
}
$Config = @($Config | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
if ($Config.Count -gt 0) {
    $Configs = @($Configs | Where-Object { $n = $_.Name; @($Config | Where-Object { $n -like $_ }).Count -gt 0 })
} else {
    $Configs = @($Configs | Where-Object { $_.Group -ne 'p' })
}
if ($Configs.Count -eq 0) { throw 'no matching configuration' }
if ($ListConfigs) { $Configs | ForEach-Object { Write-Output $_.Name }; exit 0 }

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
# The floors of the filter-off stream and of the streams with the deblocking filter in force at any picture (the filter smooths true edges of the
# synthetic patterns: lower PSNR, fewer bits).
$Floors = "$Tb/h264_psnr_floors.txt"
if ((-not $NoDbk) -and (($DbkCtl -eq '') -or ($DbkCtl -match '[1-9a-fA-F]'))) { $Floors = "$Tb/h264_psnr_floors_dbk.txt" }
$Measured = "$Sim/floors_measured.txt"

if ($BuildToolsOnly) { Write-Output 'TOOLS READY'; exit 0 }
# Verilator options that keep the model compile small: without them the bench's constant-bound loops (de-tiling, line spreading) unroll into a
# 70 MB source file and one cc1plus needs 4 to 18 GB at 720p and 1080p; with them the largest file is 0.4 MB and the compile takes seconds.
$VlExtra = '--unroll-count 8 --unroll-stmts 500 --output-split 5000'
$allOk = $true
foreach ($c in $Configs) {
    $name = $c.Name
    $label = if ($Tag -ne '') { "${name}_$Tag" } elseif ($InjectWidth) { "${name}_widthneg" } elseif ($AxiW -eq 64) { "${name}_w64" } elseif ($InjectBurst) { "${name}_burstneg" } elseif ($InjectBurstRef) { "${name}_burstrefneg" } elseif ($Inject) { "${name}_neg" } elseif ($Irq) { "${name}_irq" } else { $name }
    $dir = "$Sim/$label"
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir, "$dir/png" | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $fails = @()

    # Input frames and references.
    $refs = @()
    if ($c.Seq -ne '') {
        & $Py -I "$Tb/h264_gen.py" --seq $c.Seq --count $c.P --w $c.W --h $c.H --out "$dir/in" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "h264_gen.py failed for $name" }
        for ($n = 0; $n -lt $c.P; $n++) { $refs += "$dir/in${n}_ref.yuv" }
    } else {
        for ($n = 0; $n -lt $c.P; $n++) {
            $pat = $c.Pat[[Math]::Min($n, $c.Pat.Count - 1)]
            $frame = 0
            if ($pat -eq 'square') { $frame = 1 }
            & $Py -I "$Tb/h264_gen.py" --pattern $pat --w $c.W --h $c.H --frame $frame --seed (7 + $n) --out "$dir/in$n" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "h264_gen.py failed for $name" }
            $refs += "$dir/in${n}_ref.yuv"
        }
    }

    # Stream parameter sets from the driver.
    $toolArgs = @("$($c.W)", "$($c.H)", "$($c.W)", "$($c.DH)", '30', '4', "$dir/sps.bin")
    if ($c.W -eq 1280) { $toolArgs = @('mode', '0', '4', "$dir/sps.bin") }
    if ($c.W -eq 1920) { $toolArgs = @('mode', '1', '4', "$dir/sps.bin") }
    # The tool lives in the tool folder shared by every checkout on this machine; a harness of another checkout can be
    # rebuilding it at this moment (the file is then missing or locked for an instant), so a failed start is tried again.
    $rc = 1
    for ($try = 0; $try -lt 5 -and $rc -ne 0; $try++) {
        if ($try -gt 0) { Start-Sleep -Seconds 2 }
        try { $rc = Invoke-Tool $SpsTool $toolArgs $dir "$dir/sps_tool.log" } catch { $rc = 1 }
    }
    if ($rc -ne 0) { throw "SPS/PPS tool failed: $(Read-Text "$dir/sps_tool.log.err")" }

    # Encode in Verilator.
    $defs = @("TB_MBW=$($c.W / 16)", "TB_MBH=$($c.H / 16)", "TB_SLICES=$($c.S)", "TB_ENGINES=$($c.E)", "TB_PICS=$($c.P)", "TB_RING_KB=$($c.Ring)",
              "TB_CONSUMER_DELAY=$($c.Delay)", "TB_MEM_LOG2=$($c.Mem)", "TB_GAP=$Gap", "TB_LAT=$Lat", "TB_QP=$($c.Qp)")
    if ($Pcm -and $HasMbMode) { $defs += 'TB_PCM=1' }
    if ($NoDbk) { $defs += 'TB_DEBLOCK=0' }
    if ($AxiW -eq 64) { $defs += 'TB_AXI_W=64' }
    if ($c.ContainsKey('Stall')) { $defs += 'TB_EXPECT_STALL=1' }
    if ($c.ContainsKey('Sr')) { $defs += "TB_SR=$($c.Sr)" }
    $fdir = $dir.Replace([string][char]92, '/')
    $pa = @("INPFX=$fdir/in", "OUT=$fdir/o", "GOP=$($c.Gop)")
    if ($Inject) { $pa += 'INJECT' }
    if ($Irq) { $pa += 'IRQ' }
    if ($DbkCtl -ne '') { $pa += "DBKCTL=$DbkCtl" }
    if ($InjectBurst) { $pa += 'INJECT_BURST' }
    if ($InjectWidth) { $pa += 'INJECT_MEM' }
    if ($InjectBurstRef) { $pa += 'INJECT_BURST_REF' }
    if ($c.ContainsKey('ExpMv')) { $pa += "EXPMV_X=$($c.ExpMv[0])"; $pa += "EXPMV_Y=$($c.ExpMv[1])" }
    $simOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Repo/scripts/rtlnet_run_verilator.ps1" -Bench tb_rtlnet_h264_top `
        -Filelist cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_top.f -Tag $label -Defines ($defs -join ',') -PlusArgs ($pa -join ',') -Threads $Threads -Extra $VlExtra
    $simLine = ($simOut | Select-Object -Last 1)
    $simSecs = $sw.Elapsed.TotalSeconds
    Write-Output "[$label] bench: $simLine"
    $runLog = Read-Text "$Repo/.sim/verilator/tb_rtlnet_h264_top_$label/run.log"
    if ($AxiW -eq 64) {
        # The same configuration with 128-bit ports (bench only): the memory after the run must be the same.
        $benchRc = $LASTEXITCODE
        $defs128 = @($defs | Where-Object { $_ -ne 'TB_AXI_W=64' })
        $pa128 = @($pa | Where-Object { $_ -ne 'INJECT_MEM' } | ForEach-Object { if ($_ -like 'OUT=*') { "OUT=$fdir/ref128_o" } else { $_ } })
        $refOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Repo/scripts/rtlnet_run_verilator.ps1" -Bench tb_rtlnet_h264_top `
            -Filelist cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_top.f -Tag "${label}_ref128" -Defines ($defs128 -join ',') -PlusArgs ($pa128 -join ',') -Threads $Threads -Extra $VlExtra
        $refLine = ($refOut | Select-Object -Last 1)
        $LASTEXITCODE = $benchRc
        Write-Output "[$label] bench (128-bit reference): $refLine"
        $refLog = Read-Text "$Repo/.sim/verilator/tb_rtlnet_h264_top_${label}_ref128/run.log"
        $h64 = [regex]::Match($runLog, '(?m)^MEMHASH ([0-9a-f]+)').Groups[1].Value
        $h128 = [regex]::Match($refLog, '(?m)^MEMHASH ([0-9a-f]+)').Groups[1].Value
        $widthOk = ($h64 -ne '') -and ($h64 -eq $h128)
        Write-Output "[$label] MEMHASH 64-bit $h64, 128-bit $h128 -> $(if ($widthOk) { 'identical memory' } else { 'DIFFERENT memory' })"
        if ($InjectWidth) {
            if (-not $widthOk) { Write-Output "TEST PASS: rtlnet_h264_top_$label (negative control: the width comparison reported different memory)" }
            else { Write-Output "TEST FAIL: rtlnet_h264_top_$label (negative control: the width comparison missed the flipped memory bit)"; $allOk = $false }
            continue
        }
        if (-not $widthOk) { $fails += 'memory differs between 64-bit and 128-bit ports' }
    }
    if ($InjectBurst) {
        if (($LASTEXITCODE -ne 0) -and ($runLog -match 'burst monitor: engine 0 single-beat rebuilt-picture AW')) {
            Write-Output "TEST PASS: rtlnet_h264_top_$label (negative control: the burst monitor fired on the injected single-beat AW)"
        } else {
            Write-Output "TEST FAIL: rtlnet_h264_top_$label (negative control: the burst monitor did not fire)"; $allOk = $false
        }
        continue
    }
    if ($InjectBurstRef) {
        if (($LASTEXITCODE -ne 0) -and ($runLog -match 'burst monitor: engine 0 reference read of 4 beats')) {
            Write-Output "TEST PASS: rtlnet_h264_top_$label (negative control: the burst monitor fired on the injected 4-beat reference read)"
        } else {
            Write-Output "TEST FAIL: rtlnet_h264_top_$label (negative control: the burst monitor did not fire on the reference read)"; $allOk = $false
        }
        continue
    }
    if ($LASTEXITCODE -ne 0) { $fails += 'bench'; $allOk = $false; Write-Output "TEST FAIL: rtlnet_h264_top_$label (bench)"; continue }
    foreach ($m in [regex]::Matches($runLog, '(?m)^(STAT|HIST|SUMMARY) [^\r\n]*')) { Write-Output "[$label] $($m.Value)" }
    # Search quality (phase 2c-2): the macroblocks of every P picture whose block at the expected vector lies inside the picture must carry it.
    if ($c.ContainsKey('ExpMv')) {
        foreach ($m in [regex]::Matches($runLog, '(?m)^MVSTAT pic(\d+) interior=(\d+) true=(\d+)')) {
            $mi = [int]$m.Groups[2].Value; $mt = [int]$m.Groups[3].Value
            $pct = if ($mi -gt 0) { 100.0 * $mt / $mi } else { 100.0 }
            Write-Output ("[{0}] MVSTAT pic{1} interior={2} true={3} ({4:N1} %)" -f $label, $m.Groups[1].Value, $mi, $mt, $pct)
            if (($mi -gt 0) -and ($mt * 10 -lt $mi * 9)) { $fails += "search quality pic$($m.Groups[1].Value)" }
        }
    }
    # Clocks per macroblock (PIC_CYC / MB_COUNT of an engine) over the I and the P pictures of the run: min, mean, max per picture type.
    $cpm = @{ I = @(); P = @() }
    foreach ($m in [regex]::Matches($runLog, '(?m)^STAT pic(\d+) eng(\d+) PIC_CYC=(\d+) type=([IP])\s*\r?\n^STAT pic\d+ eng\d+ MB_COUNT=(\d+)')) {
        $cpm[$m.Groups[4].Value] += ([double]$m.Groups[3].Value / [double]$m.Groups[5].Value)
    }
    foreach ($t in 'I', 'P') {
        if ($cpm[$t].Count -gt 0) {
            $st = $cpm[$t] | Measure-Object -Minimum -Maximum -Average
            Write-Output ("[{0}] CLK_PER_MB {1} pictures x engines {2}: min {3:N0} mean {4:N0} max {5:N0}" -f $label, $t, $st.Count, $st.Minimum, $st.Average, $st.Maximum)
        }
    }

    # Assemble stream and rebuilt YUV; rebuilt must equal the reference.
    $asmExtra = @('--pattern', ($c.Pat -join ','), '--qp', "$($c.Qp)", '--floors', $Floors, '--gop', $c.Gop, '--slices', "$($c.S)")
    if ($c.AllSkip) { $asmExtra += '--allskip' }
    if ($PcmChecks) { $asmExtra += '--pcm' }
    if ($Measure -or $Inject) { $asmExtra += '--measure' }
    $asm = & $Py -I "$Tb/h264_check.py" assemble --dir $dir --prefix "$dir/o" --spspps "$dir/sps.bin" --pics $c.P --disp-h $c.DH --refs @refs @asmExtra
    $asm | ForEach-Object {
        Write-Output "[$label] $_"
        if ($Measure -and ($_ -match '^FLOOR \S+ \d+ [\d.]+$')) { try { [System.IO.File]::AppendAllText($Measured, "$_`n") } catch { Start-Sleep -Milliseconds 200; try { [System.IO.File]::AppendAllText($Measured, "$_`n") } catch { } } }
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
        # A passed run keeps its logs and results: the Verilator object tree and the bulky YUV / hex intermediates go (disk rule of the project).
        if ($fails.Count -eq 0) {
            foreach ($sub in 'obj', 'tmp') { $q = "$Repo/.sim/verilator/tb_rtlnet_h264_top_$label/$sub"; if (Test-Path -LiteralPath $q) { Remove-Item -LiteralPath $q -Recurse -Force -ErrorAction SilentlyContinue } }
            Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.yuv', '.hex' -and $_.Length -gt 2MB } | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        else { Write-Output "TEST FAIL: rtlnet_h264_top_$label ($($fails -join ', '))"; $allOk = $false }
    }
}
if (-not $allOk) { exit 1 }
exit 0
