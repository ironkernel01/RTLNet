// -----------------------------------------------------------------------------
// File: tb_h264_cavlc_ref.svh
// Purpose: bench-side reference of the CAVLC encoder (ITU-T Rec. H.264 clause 9.2 and 9.1): bit-string builders and a
//   residual_block_cavlc encoder written for the benches tb_rtlnet_h264_cavlc and tb_rtlnet_h264_mbcavlc. Included inside the
//   bench module, after tb_h264_cavlc_ref_tab.svh (the bench's own copy of the code tables).
// Overview:
//   * The reference works on arrays of whole numbers and a queue of bits, not on the RTL's fields: trailing ones are counted
//     from the end of the non-zero list, a level is coded by searching the smallest level_prefix whose decode range
//     (clause 9.2.2.1: levelCode = (Min(15, prefix) << suffixLength) + suffix, +15 when prefix >= 15 and suffixLength 0,
//     suffix size 4 for prefix 14 at suffixLength 0, prefix - 3 from prefix 15) holds the level code, total_zeros and
//     run_before follow the clause 9.2.3 and 9.2.4 order.
//   * ref_hit_ct[cls][tc][t1] counts the coeff_token entries exercised.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
typedef bit bitq_t[$];

int ref_hit_ct [5][17][4];

function automatic void put_bits(ref bitq_t q, input longint unsigned v, input int len);
  for (int i = len - 1; i >= 0; i--) q.push_back(v[i]);
endfunction

// ue(v), clause 9.1.
function automatic void put_ue(ref bitq_t q, input longint unsigned codenum);
  longint unsigned n;
  int len;
  n   = codenum + 1;
  len = 0;
  while ((n >> (len + 1)) != 0) len++;
  put_bits(q, 0, len);
  put_bits(q, n, len + 1);
endfunction

// se(v), clause 9.1.1.
function automatic void put_se(ref bitq_t q, input int v);
  if (v > 0) put_ue(q, 2 * v - 1);
  else       put_ue(q, -2 * v);
endfunction

// One residual block. coef holds the levels in coding order; only the first maxc entries count; cls is the coeff_token table
// class (0..2 nC bands, 3 nC >= 8, 4 chroma DC). Returns TotalCoeff.
function automatic int ref_block(ref bitq_t q, input int maxc, input int cls, input int coef[16]);
  int lv [$];
  int ps [$];
  int tc, t1, sl, level, lc, prefix, sufsz, base, lastpos, tz, zl, run, a;
  bit found;
  for (int k = 0; k < maxc; k++) begin
    if (coef[k] != 0) begin
      lv.push_back(coef[k]);
      ps.push_back(k);
    end
  end
  tc = lv.size();
  t1 = 0;
  while ((t1 < 3) && (t1 < tc) && ((lv[tc - 1 - t1] == 1) || (lv[tc - 1 - t1] == -1))) t1++;
  ref_hit_ct[cls][tc][t1]++;
  put_bits(q, REF_CT_CODE[cls][tc][t1], REF_CT_LEN[cls][tc][t1]);
  for (int i = 0; i < t1; i++) put_bits(q, (lv[tc - 1 - i] < 0) ? 1 : 0, 1);
  sl = ((tc > 10) && (t1 < 3)) ? 1 : 0;
  for (int i = t1; i < tc; i++) begin
    level = lv[tc - 1 - i];
    lc    = (level > 0) ? (2 * level - 2) : (-2 * level - 1);
    if ((i == t1) && (t1 < 3)) lc -= 2;
    found = 0;
    prefix = 0;
    sufsz = 0;
    base = 0;
    for (int p = 0; p <= 15; p++) begin
      if (!found) begin
        sufsz = ((p == 14) && (sl == 0)) ? 4 : ((p >= 15) ? (p - 3) : sl);
        base  = (((p > 15) ? 15 : p) << sl) + (((p >= 15) && (sl == 0)) ? 15 : 0);
        if ((lc >= base) && (lc < base + (1 << sufsz))) begin
          found  = 1;
          prefix = p;
        end
      end
    end
    if (!found) $display("REF ERROR: level %0d not codable (sl %0d)", level, sl);
    put_bits(q, 0, prefix);
    put_bits(q, 1, 1);
    put_bits(q, lc - base, sufsz);
    if (sl == 0) sl = 1;
    a = (level < 0) ? -level : level;
    if ((a > (3 << (sl - 1))) && (sl < 6)) sl++;
  end
  if ((tc > 0) && (tc < maxc)) begin
    lastpos = ps[tc - 1];
    tz = lastpos + 1 - tc;
    if (maxc == 4) put_bits(q, REF_TZC_CODE[tc][tz], REF_TZC_LEN[tc][tz]);
    else           put_bits(q, REF_TZ_CODE[tc][tz], REF_TZ_LEN[tc][tz]);
    zl = tz;
    for (int i = tc - 1; i >= 1; i--) begin
      if (zl > 0) begin
        run = ps[i] - ps[i - 1] - 1;
        put_bits(q, REF_RB_CODE[(zl > 6) ? 7 : zl][run], REF_RB_LEN[(zl > 6) ? 7 : zl][run]);
        zl -= run;
      end
    end
  end
  return tc;
endfunction

function automatic int ref_cls(input int maxc, input int nc);
  if (maxc == 4) return 4;
  if (nc < 2) return 0;
  if (nc < 4) return 1;
  if (nc < 8) return 2;
  return 3;
endfunction
