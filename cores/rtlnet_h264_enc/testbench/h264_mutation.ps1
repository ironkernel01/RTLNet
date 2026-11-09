<#
-------------------------------------------------------------------------------
File: h264_mutation.ps1
Purpose: mutation tests of rtlnet_h264_top: each mutation edits one RTL line, runs the benches or the decoder harness
  that must catch it, and restores the file byte for byte (checked by SHA-256).
Overview:
  * Mutations: (1) emulation prevention off in rtlnet_h264_bitpack, (2) chroma rounding changed to floor in
    rtlnet_h264_c422to420, (3) first_mb_in_slice wrong for slice 2 in rtlnet_h264_engine, (4) the ring-full guard
    removed in rtlnet_h264_ring_wr.
  * A mutation is CAUGHT when every listed check fails (non-zero exit). The file is restored in a finally block.
  * Prints `MUTATION <n> <name>: CAUGHT|SURVIVED ...` and `MUTATION RESULT: <caught> of <total> caught`; exit 0 only when
    all are caught and every file is restored identical.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_mutation.ps1
Revision: 11-09-2026
  * 11-09-2026: initial version.
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$Hdl = Join-Path $Repo 'cores/rtlnet_h264_enc/hdl'
$Tb = Join-Path $Repo 'cores/rtlnet_h264_enc/testbench'
$Vl = Join-Path $Repo 'scripts/rtlnet_run_verilator.ps1'

$Muts = @(
    @{ Name = 'emulation prevention off'; File = 'rtlnet_h264_bitpack.sv';
       Old = "assign ep_ins  = ob_valid && !ob_raw && (z == 2'd2) && (ob_data <= 8'h03);"; New = "assign ep_ins  = 1'b0;";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_bitpack'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_bitpack.f' },
                  @{ Kind = 'harness'; Config = 'qcif_zeros' }) },
    @{ Name = 'chroma rounding floor'; File = 'rtlnet_h264_c422to420.sv';
       Old = "{1'b0, chroma_cur[8*b +: 8]} + 9'd1) >> 1);"; New = "{1'b0, chroma_cur[8*b +: 8]} + 9'd0) >> 1);";
       Checks = @(@{ Kind = 'bench'; Bench = 'tb_rtlnet_h264_c422'; Fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_c422.f' },
                  @{ Kind = 'harness'; Config = 'qcif_s1' }) },
    @{ Name = 'first_mb_in_slice wrong for slice 2'; File = 'rtlnet_h264_engine.sv';
       Old = "E_H2: begin seq_op = PK_UE; seq_val = mbn; end"; New = "E_H2: begin seq_op = PK_UE; seq_val = mbn + ((slice_idx == 8'd1) ? 32'd1 : 32'd0); end";
       Checks = @(@{ Kind = 'harness'; Config = 'qcif_s3' }) },
    @{ Name = 'ring full guard removed'; File = 'rtlnet_h264_ring_wr.sv';
       Old = "assign ring_room = room_q;"; New = "assign ring_room = 1'b1;";
       Checks = @(@{ Kind = 'harness'; Config = 'qcif_ring' }) }
)

function Get-Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

$caught = 0
$allRestored = $true
$i = 0
foreach ($m in $Muts) {
    $i++
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
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tb 'h264_harness.ps1') -Config $c.Config -NoPng
                $failed = ($LASTEXITCODE -ne 0)
                $results += @{ What = "harness $($c.Config)"; Failed = $failed; Line = ($out | Where-Object { $_ -match '^TEST|MISMATCH|%Error|bench:' } | Select-Object -Last 1) }
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
Write-Output "MUTATION RESULT: $caught of $($Muts.Count) caught, restored identical: $allRestored"
if (($caught -ne $Muts.Count) -or -not $allRestored) { exit 1 }
exit 0
