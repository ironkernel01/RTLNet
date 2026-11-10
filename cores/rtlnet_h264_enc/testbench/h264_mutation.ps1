<#
-------------------------------------------------------------------------------
File: h264_mutation.ps1
Purpose: mutation tests of rtlnet_h264_top: each mutation edits one RTL line, runs the benches or the decoder harness
  that must catch it, and restores the file byte for byte (checked by SHA-256).
Overview:
  * Mutations 1 and 2 are checked in the global I_PCM mode of the harness (-Pcm): with lossy coding the stream of the `zeros` content
    has no long zero runs and the chroma rounding is invisible against the PSNR floor, but the I_PCM picture must equal the
    source exactly. Mutation 5 (a one-LSB quantizer constant) is a legal encoder choice a decoder cannot see, so only the transform
    bench can catch it.
  * Mutations: (1) emulation prevention off in rtlnet_h264_bitpack, (2) chroma rounding changed to floor in
    rtlnet_h264_c422to420, (3) first_mb_in_slice wrong for slice 2 in rtlnet_h264_engine, (4) the ring-full guard
    removed in rtlnet_h264_ring_wr, (5) one wrong quant multiplier in rtlnet_h264_fwdq, (6) a wrong coeff_token table
    entry in rtlnet_h264_cavlc_tab, (7) plane prediction rounding in rtlnet_h264_ipred, (8) nC from the wrong neighbour in
    rtlnet_h264_mb_cavlc, (9) DC prediction with a missing neighbour in rtlnet_h264_ipred, (10) the I_PCM fallback never taken
    (rtlnet_h264_mb_enc), (11) the saturated DC level flag of the fallback removed (the root cause of the QP 0 failure) (rtlnet_h264_mb_enc), (12) an I_PCM macroblock
    counted as 0 coefficients for the neighbours' nC (rtlnet_h264_mb_cavlc), (13) the 32-bit limit of a merged level pair
    exceeded (rtlnet_h264_cavlc_blk). P-path mutations (phase 2c-1): (14) a wrong inter coded_block_pattern code (rtlnet_h264_pkg),
    (15) mb_skip_run off by one (rtlnet_h264_mb_cavlc), (16) the reference chroma tile pointer advancing by the luma tile size
    (rtlnet_h264_engine), (17) P_Skip chosen although luma levels are coded (rtlnet_h264_mb_enc), (18) the intra rounding offset used
    for inter blocks (rtlnet_h264_fwdq: a legal encoder choice a decoder cannot see, only the transform bench catches it),
    (19) the single-matching-reference rule ignoring neighbour C (rtlnet_h264_mvpred: mvp is always 0 in stage 2c-1, so only the
    mvpred bench catches it).
  * A mutation is CAUGHT when every listed check fails (non-zero exit). The file is restored in a finally block.
  * Prints `MUTATION <n> <name>: CAUGHT|SURVIVED ...` and `MUTATION RESULT: <caught> of <total> caught`; exit 0 only when
    all are caught and every file is restored identical.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_mutation.ps1 [-Only <mutation numbers>]
Revision: 11-10-2026
  * 11-09-2026: initial version; mutations 10 to 13 (I_PCM fallback, level pair merge).
  * 11-10-2026: mutations 14 to 19 (P path).
-------------------------------------------------------------------------------
#>
param([string]$Only = '')   # comma separated mutation numbers, e.g. 1,2,5; all when empty
$ErrorActionPreference = 'Stop'
$OnlySet = @(); if ($Only -ne '') { $OnlySet = @($Only -split ',' | ForEach-Object { [int]$_ }) }
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$Hdl = Join-Path $Repo 'cores/rtlnet_h264_enc/hdl'
$Tb = Join-Path $Repo 'cores/rtlnet_h264_enc/testbench'
$Vl = Join-Path $Repo 'scripts/rtlnet_run_verilator.ps1'

$Muts = @(
    @{ Name = 'emulation prevention off'; File = 'rtlnet_h264_bitpack.sv';
       Old = "assign ep_ins  = ob_valid && !ob_raw && (z == 2'd2) && (ob_data <= 8'h03);"; New = "assign ep_ins  = 1'b0;";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_bitpack'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_bitpack.f' },
                  @{ Kind = 'harness'; Config = 'qcif_zeros'; Pcm = $true }) },
    @{ Name = 'chroma rounding floor'; File = 'rtlnet_h264_c422to420.sv';
       Old = "{1'b0, chroma_cur[8*b +: 8]} + 9'd1) >> 1);"; New = "{1'b0, chroma_cur[8*b +: 8]} + 9'd0) >> 1);";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_c422'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_c422.f' },
                  @{ Kind = 'harness'; Config = 'qcif_s1'; Pcm = $true }) },
    @{ Name = 'first_mb_in_slice wrong for slice 2'; File = 'rtlnet_h264_engine.sv';
       Old = "E_H2: begin seq_op = PK_UE; seq_val = mbn; end"; New = "E_H2: begin seq_op = PK_UE; seq_val = mbn + ((slice_idx == 8'd1) ? 32'd1 : 32'd0); end";
       Checks = @(@{ Kind = 'harness'; Config = 'qcif_s3' }) },
    @{ Name = 'ring full guard removed'; File = 'rtlnet_h264_ring_wr.sv';
       Old = "assign ring_room = room_q;"; New = "assign ring_room = 1'b1;";
       Checks = @(@{ Kind = 'harness'; Config = 'qcif_ring' }) },
    @{ Name = 'one wrong quant multiplier'; File = 'rtlnet_h264_fwdq.sv';
       Old = "3'd3:    r = (cls == 2'd0) ? 14'd9362  : ((cls == 2'd1) ? 14'd3647 : 14'd5825);";
       New = "3'd3:    r = (cls == 2'd0) ? 14'd9362  : ((cls == 2'd1) ? 14'd3648 : 14'd5825);";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_xform'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_xform.f' }) },
    @{ Name = 'wrong coeff_token table entry'; File = 'rtlnet_h264_cavlc_tab.sv';
       Old = "{3'd0,5'd1,2'd0}: e = {5'd6, 6'd5};"; New = "{3'd0,5'd1,2'd0}: e = {5'd6, 6'd4};";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_cavlc'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_cavlc.f' },
                  @{ Kind = 'harness'; Config = 'qcif_photo_q28' }) },
    @{ Name = 'plane prediction rounding'; File = 'rtlnet_h264_ipred.sv';
       Old = "20'(k_a) + 20'sd16 - k_cbc"; New = "20'(k_a) + 20'sd15 - k_cbc";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_ipred'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_ipred.f' },
                  @{ Kind = 'harness'; Config = 'qcif_gradient_q28' }) },
    @{ Name = 'nC from the wrong neighbour'; File = 'rtlnet_h264_mb_cavlc.sv';
       Old = "lc[{nby - 2'd1, 2'b00} + {2'b00, nbx}] : tl_l[nbx];"; New = "lc[{nby - 2'd1, 2'b00} + {2'b00, nbx}] : ll[nby];";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_mbcavlc'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_mbcavlc.f' },
                  @{ Kind = 'harness'; Config = 'qcif_gradnoise_q18' }) },
    @{ Name = 'DC prediction with a missing neighbour'; File = 'rtlnet_h264_ipred.sv';
       Old = "dc_y <= 8'((sum_top_y + 12'd8) >> 4);"; New = "dc_y <= 8'((sum_top_y + 12'd16) >> 5);";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_ipred'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_ipred.f' },
                  @{ Kind = 'harness'; Config = 'qcif_edges_q18' }) },
    @{ Name = 'I_PCM fallback never taken'; File = 'rtlnet_h264_mb_enc.sv';
       Old = "if (ovf_q || (est_tot > 16'(EST_LIMIT))) begin"; New = "if (1'b0) begin";
       Checks = @(@{ Kind = 'harness'; Config = 'qcif_checker_q0' }) },
    @{ Name = 'saturated DC level flag removed'; File = 'rtlnet_h264_mb_enc.sv';
       Old = "if (|w_sat) ovf_q <= 1'b1;"; New = "if (1'b0) ovf_q <= 1'b1;";
       Checks = @(@{ Kind = 'harness'; Config = 'qcif_checker_q0' }) },
    @{ Name = 'I_PCM macroblock counted as 0 coefficients for nC'; File = 'rtlnet_h264_mb_cavlc.sv';
       Old = "lc[i] <= pcm ? 5'd16 : 5'd0;"; New = "lc[i] <= pcm ? 5'd0 : 5'd0;";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_mbcavlc'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_mbcavlc.f' }) },
    @{ Name = 'level pair merge limit exceeded'; File = 'rtlnet_h264_cavlc_blk.sv';
       Old = "{1'b0, len3b} > 7'd32);"; New = "{1'b0, len3b} > 7'd33);";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_cavlc'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_cavlc.f' }) },
    @{ Name = 'wrong inter coded_block_pattern code'; File = 'rtlnet_h264_pkg.sv';
       Old = "6'd31: r = 6'd19;"; New = "6'd31: r = 6'd20;";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_mbcavlc'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_mbcavlc.f' },
                  @{ Kind = 'harness'; Config = 'p_qcif_pan_q12' }) },
    @{ Name = 'mb_skip_run off by one'; File = 'rtlnet_h264_mb_cavlc.sv';
       Old = "C_SR: begin cmd_valid = 1'b1; cmd_op = PK_UE; cmd_val = 32'(run_q); end"; New = "C_SR: begin cmd_valid = 1'b1; cmd_op = PK_UE; cmd_val = 32'(run_q) + 32'd1; end";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_mbcavlc'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_mbcavlc.f' },
                  @{ Kind = 'harness'; Config = 'p_qcif_cut_q28' }) },
    @{ Name = 'reference chroma pointer step wrong'; File = 'rtlnet_h264_engine.sv';
       Old = "rfu_ptr   <= rfu_ptr + ADDR_W'(REC_CHROMA_TILE_BYTES);"; New = "rfu_ptr   <= rfu_ptr + ADDR_W'(REC_LUMA_TILE_BYTES);";
       Checks = @(@{ Kind = 'harness'; Config = 'p_qcif_pan_q28' }) },
    @{ Name = 'P_Skip chosen with coded luma levels'; File = 'rtlnet_h264_mb_enc.sv';
       Old = "o_skip       <= inter_q && (nz8_e == 4'd0) && (drop_q"; New = "o_skip       <= inter_q && (drop_q";
       Checks = @(@{ Kind = 'harness'; Config = 'p_qcif_pan_q28' }) },
    @{ Name = 'intra rounding offset used for inter blocks'; File = 'rtlnet_h264_fwdq.sv';
       Old = "(q1_inter ? (32'(f_of(q1_q6)) >> 1) : 32'(f_of(q1_q6)))"; New = "32'(f_of(q1_q6))";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_xform'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_xform.f' }) },
    @{ Name = 'single matching reference index: neighbour C ignored'; File = 'rtlnet_h264_mvpred.sv';
       Old = "mvp_x = ra ? ax : (rb ? bx : cx);"; New = "mvp_x = ra ? ax : (rb ? bx : ax);";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_mvpred'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_mvpred.f' }) }
)

function Get-Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

$caught = 0
$allRestored = $true
$i = 0
foreach ($m in $Muts) {
    $i++
    if (($OnlySet.Count -gt 0) -and ($OnlySet -notcontains $i)) { continue }
    $path = Join-Path $Hdl $m.File
    $before = Get-Sha $path
    $orig = [System.IO.File]::ReadAllBytes($path)
    $text = [System.IO.File]::ReadAllText($path)
    if (-not $text.Contains($m.Old)) { Write-Output "MUTATION $i $($m.Name): SKIPPED (pattern not found)"; continue }
    $results = @()
    try {
        [System.IO.File]::WriteAllText($path, $text.Replace($m.Old, $m.New), (New-Object System.Text.UTF8Encoding($false)))
        foreach ($c in $m.Checks) {
            if ($c.Kind -eq 'bench') {
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Vl -Bench $c.Bench -Filelist $c.Fl -Tag "mut$i"
                $failed = ($LASTEXITCODE -ne 0)
                $results += @{ What = $c.Bench; Failed = $failed; Line = ($out | Select-Object -Last 1) }
            } else {
                $hargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Tb 'h264_harness.ps1'), '-Config', $c.Config, '-NoPng')
                if ($c.Pcm) { $hargs += '-Pcm' }
                $out = & powershell.exe @hargs
                $failed = ($LASTEXITCODE -ne 0)
                $results += @{ What = "harness $($c.Config)$(if ($c.Pcm) { ' -Pcm' } else { '' })"; Failed = $failed; Line = ($out | Where-Object { $_ -match '^TEST|MISMATCH|%Error|bench:' } | Select-Object -Last 1) }
            }
        }
    } finally {
        [System.IO.File]::WriteAllBytes($path, $orig)
    }
    $after = Get-Sha $path
    if ($after -ne $before) { $allRestored = $false; Write-Output "MUTATION $i $($m.Name): RESTORE MISMATCH $before $after" }
    $all = $true
    foreach ($r in $results) {
        Write-Output "  $($r.What): failed=$($r.Failed) | $($r.Line)"
        if (-not $r.Failed) { $all = $false }
    }
    if ($all) { $caught++; Write-Output "MUTATION $i $($m.Name): CAUGHT (file restored, SHA-256 identical)" }
    else { Write-Output "MUTATION $i $($m.Name): SURVIVED" }
}
Write-Output "MUTATION RESULT: $caught of $($(if ($OnlySet.Count -gt 0) { $OnlySet.Count } else { $Muts.Count })) caught, restored identical: $allRestored"
$expect = if ($OnlySet.Count -gt 0) { $OnlySet.Count } else { $Muts.Count }
if (($caught -ne $expect) -or -not $allRestored) { exit 1 }
exit 0
