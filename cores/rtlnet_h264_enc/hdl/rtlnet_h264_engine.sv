// -----------------------------------------------------------------------------
// File: rtlnet_h264_engine.sv
// Purpose: one H.264 encoder engine: codes a band of macroblock rows of a picture as slices of whole
//   macroblock rows, through read DMA, macroblock coder, bit packer, ring writer and rebuilt-picture
//   writer, on one AXI4 master.
// Overview:
//   * Picture sequence: access unit delimiter NAL unit, then per slice a slice NAL unit (slice header from
//     the register fields, one macroblock layer per macroblock, rbsp_slice_trailing_bits). With S
//     slices over R rows, the first R mod S slices have floor(R / S) + 1 rows and the rest floor(R / S).
//     The slices are coded one after another; the engine waits for each slice's last byte to be accepted
//     by the ring writer (which then samples the slice metadata) before it starts the next one.
//   * Slice header (clause 7.3.3, IDR or non-IDR I slice, entropy_coding_mode_flag 0, frame_mbs_only 1,
//     pic_order_cnt_type 2, deblocking_filter_control_present_flag 1): first_mb_in_slice ue(v), slice_type ue(v) = 7,
//     pic_parameter_set_id ue(v) = 0, frame_num u(log2_max_frame_num), idr_pic_id ue(v) (IDR only),
//     dec_ref_pic_marking (clause 7.3.3.3: IDR no_output_of_prior_pics_flag 0 and long_term_reference_flag 0;
//     non-IDR adaptive_ref_pic_marking_mode_flag 0), slice_qp_delta se(v) = QP - 26, disable_deblocking_filter_idc
//     ue(v) = 1 (deblocking off). nal_ref_idc is 3; nal_unit_type is 5 (IDR) or 1.
//   * Source strips: the read DMA fetches a strip of RD_STRIP_MB macroblocks of one macroblock row per start (row bursts of
//     2 * RD_STRIP_MB beats) into one half of the strip buffer (RD_STRIP_MB banks of 24 words, 32-word pitch); the two halves
//     alternate. The fetch sequencer fills a free half while stage A codes the macroblocks of the other, in raster order; the
//     last strip of a macroblock row holds the remaining macroblocks (fewer than RD_STRIP_MB when the width is not a multiple).
//   * Rebuilt picture: macroblock-tiled (rtlnet_h264_recon_wr): luma tile of macroblock m at cfg_ry_base + 256 * m, chroma
//     tile (Cb then Cr) at cfg_ru_base + 128 * m, m the raster index in the picture; each tile is one burst.
//   * Macroblock pipeline: the fetch sequencer fills the strip halves through the read DMA in raster order. Stage A
//     (rtlnet_h264_mb_enc: Intra16x16 decision, transform, quantizer, rebuild loop) codes one macroblock from a source
//     bank into a coefficient bank and a rebuilt bank; stage B (rtlnet_h264_mb_cavlc) turns the coefficient bank of the
//     previous macroblock into packer commands meanwhile; the rebuilt-picture writer drains the rebuilt bank. The
//     source bank is released when stage A is done, so stage A (about 375 clocks) is the throughput limit for smooth
//     content; stage B (two block coders in ping-pong, two levels and two run_before codes per command) stays below it for
//     content at QP 12 and above. A macroblock whose levels reach the baseline limit or whose estimated CAVLC size
//     exceeds the I_PCM size is coded as I_PCM: stage A copies the source into the rebuilt bank and the coefficient bank
//     (a_pcm), and stage B writes the I_PCM macroblock layer from the coefficient bank. cfg_mb_pcm forces that for every
//     macroblock (debug).
//   * Band: band_first_row and band_rows select the macroblock rows of this engine (the whole picture for
//     NUM_ENGINES = 1); eng_slices slices of whole rows are coded inside the band, numbered from slice_base in
//     the picture. Only the engine with EMIT_AUD writes the access unit delimiter.
//   * P pictures (phase 2c-1, cfg_p): slice_type 5, nal_unit_type 1, slice header with num_ref_idx_active_override_flag 0,
//     ref_pic_list_modification_flag_l0 0 and adaptive_ref_pic_marking_mode_flag 0 (three zero bits after frame_num). Phase 2c-2: the
//     motion search stage (rtlnet_h264_search) runs one macroblock ahead of stage A: per macroblock of the band, in raster order, it
//     searches the integer vector in its sliding window of reference tiles (cfg_refy_base and cfg_refu_base: the tile bases of the
//     previous picture's rebuilt tiles; one column of 16-beat luma and 8-beat chroma tile bursts per macroblock, AXI ID 1) and writes the
//     prediction at that vector into a bank of the prediction buffer (the 2c-1 reference macroblock buffer), the vector into
//     xmv_x / xmv_y of the bank. The search reads the luma rows of the macroblock from the strip buffer through the read port in the
//     clocks stage A does not use it. The strip DMA and the window loader share the AR and R channels one at a time (the strip
//     reads use ID 0); the loader starts only while the strip DMA is idle and no strip start is pending, and the strip sequencer
//     only while the loader is idle. Stage A starts a macroblock of a P picture when its prediction bank is full.
//     mb_skip_run of the trailing skipped macroblocks of a slice is written in state E_SKR before the slice's trailing bits. A P
//     picture must not be an IDR picture (rejected at start).
//   * Statistics (cleared at start): cycles between successive macroblock starts (last, max), cycles of
//     the whole picture, and busy cycles of the read DMA, the macroblock coder (stage A, B or I_PCM) and the write master.
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-09-2026: initial version (I_PCM); phase 2b-2: stage A / stage B macroblock coder, rebuilt and coefficient RAMs,
//     per-macroblock I_PCM fallback (rtlnet_h264_mb_pcm removed).
//   * 11-10-2026: burst-only DDR3 access: strip read DMA, tiled rebuilt picture, 128-byte index records.
//   * 11-10-2026: phase 2c-1: P pictures (reference fetch, skip runs, P slice header).
//   * 11-10-2026: phase 2c-2: motion search stage and search window replace the co-located reference fetch.
// Clocks: clk (all logic).
// -----------------------------------------------------------------------------
module rtlnet_h264_engine #(
  parameter int    ADDR_W    = 32,
  parameter int    ID_W      = 4,
  parameter int    MAX_MB_W  = 120,
  parameter int    MAX_MB_H  = 68,
  parameter int    MB_BUF_KB = 4,      // strip buffer: two halves of RD_STRIP_MB banks of 32 words (needs >= RD_STRIP_MB KiB)
  parameter int    RD_STRIP_MB = 4,    // macroblocks per read burst strip (2, 4 or 8)
  parameter int    REC_BUF_KB = 1,
  parameter int    COEF_BUF_KB = 1,
  parameter int    LINE_KB   = 4,
  parameter int    FIFO_KB   = 1,
  parameter int    REF_BUF_KB = 1,     // prediction buffer: two banks of 32 words of 16 bytes (24 used), KiB
  parameter int    MV_LINE_KB = 1,     // motion vector line RAMs (stage A's context and the search's): one 32-bit word per macroblock column
  parameter int    WIN_KB     = 4,     // each of the two search window RAMs, KiB
  parameter int    SR         = 16,    // search range in whole samples (at most 16)
  parameter bit    EMIT_AUD  = 1'b1,   // this engine writes the access unit delimiter (engine 0)
  parameter string RAM_STYLE = "block"
)(
  // Clock and synchronous active-low reset.
  input  logic              clk,
  input  logic              resetn,

  // Picture control, clk domain: start pulses one clock when idle; busy is high from start to done; done and the
  // error pulses last one clock (err_cfg: start rejected, illegal setting; err_axi: a response other than OKAY;
  // err_rptr: rejected read-pointer write; err_busy: start while busy).
  input  logic              start,
  output logic              busy,
  output logic              done,
  output logic              err_cfg,
  output logic              err_axi,
  output logic              err_rptr,
  output logic              err_busy,

  // Picture configuration, clk domain, stable while busy. Base addresses and the input stride in bytes; cfg_ry_base and
  // cfg_ru_base are the rebuilt picture's luma and chroma tile bases.
  input  logic [7:0]        cfg_mb_w,
  input  logic [7:0]        cfg_mb_h,
  input  logic [7:0]        eng_slices,
  input  logic [7:0]        slice_base,
  input  logic [ADDR_W-1:0] cfg_in_base,
  input  logic [ADDR_W-1:0] cfg_in_stride,
  input  logic [ADDR_W-1:0] cfg_ry_base,
  input  logic [ADDR_W-1:0] cfg_ru_base,
  input  logic              cfg_p,
  input  logic [ADDR_W-1:0] cfg_refy_base,
  input  logic [ADDR_W-1:0] cfg_refu_base,
  input  logic [5:0]        cfg_qp,
  input  logic              cfg_mb_pcm,
  input  logic [15:0]       cfg_frame_num,
  input  logic [15:0]       cfg_idr_pic_id,
  input  logic              cfg_idr,
  input  logic [4:0]        cfg_log2_fn,
  input  logic [15:0]       cfg_pic_no,
  input  logic [7:0]        band_first_row,
  input  logic [7:0]        band_rows,

  // Ring and index-ring configuration and read-pointer writes, clk domain.
  input  logic [ADDR_W-1:0] cfg_ring_base,
  input  logic [31:0]       cfg_ring_size,
  input  logic [ADDR_W-1:0] cfg_idx_base,
  input  logic [31:0]       cfg_idx_entries,
  input  logic              ring_reset,
  input  logic              rptr_wr,
  input  logic [31:0]       rptr_val,
  input  logic              idx_rptr_wr,
  input  logic [31:0]       idx_rptr_val,

  // Status and statistics, clk domain.
  output logic [31:0]       ring_wptr,
  output logic [31:0]       ring_fill,
  output logic [31:0]       idx_wptr,
  output logic [31:0]       idx_fill,
  output logic              ring_stall,
  output logic [31:0]       st_mb_count,
  output logic              st_slice_pulse,
  output logic [31:0]       st_cyc_last,
  output logic [31:0]       st_cyc_max,
  output logic [31:0]       st_pic_cyc,
  output logic [31:0]       st_rd_cyc,
  output logic [31:0]       st_pk_cyc,
  output logic [31:0]       st_wr_cyc,

  // AXI4 master, clk domain: read channels for the input frame, write channels for the ring, the index ring and
  // the rebuilt picture. INCR full-width bursts of at most 16 beats that never cross 4 KiB.
  output logic [ID_W-1:0]   m_arid,
  output logic [ADDR_W-1:0] m_araddr,
  output logic [7:0]        m_arlen,
  output logic [2:0]        m_arsize,
  output logic [1:0]        m_arburst,
  output logic              m_arvalid,
  input  logic              m_arready,
  input  logic [127:0]      m_rdata,
  input  logic [1:0]        m_rresp,
  input  logic              m_rlast,
  input  logic              m_rvalid,
  output logic              m_rready,
  output logic [ID_W-1:0]   m_awid,
  output logic [ADDR_W-1:0] m_awaddr,
  output logic [7:0]        m_awlen,
  output logic [2:0]        m_awsize,
  output logic [1:0]        m_awburst,
  output logic              m_awvalid,
  input  logic              m_awready,
  output logic [127:0]      m_wdata,
  output logic [15:0]       m_wstrb,
  output logic              m_wlast,
  output logic              m_wvalid,
  input  logic              m_wready,
  input  logic [ID_W-1:0]   m_bid,
  input  logic [1:0]        m_bresp,
  input  logic              m_bvalid,
  output logic              m_bready
);

  import rtlnet_h264_pkg::*;

  localparam int BANK_WORDS = 32;
  localparam int RAM_AW     = $clog2(MB_BUF_KB * 1024 / 16);
  localparam int MI         = $clog2(RD_STRIP_MB);
  localparam int REC_AW     = $clog2(REC_BUF_KB * 1024 / 4);
  localparam int REC_BANK   = 128;
  localparam int CRAM_AW    = $clog2(COEF_BUF_KB * 1024 * 8 / 48);
  localparam int COEF_BANK  = 128;
  localparam int REF_AW     = $clog2(REF_BUF_KB * 1024 / 16);
  localparam int REF_BANK   = 32;

  // Sequencer states.
  localparam logic [4:0] E_IDLE   = 5'd0;
  localparam logic [4:0] E_DIV    = 5'd1;
  localparam logic [4:0] E_PTR    = 5'd2;
  localparam logic [4:0] E_AUD0   = 5'd3;
  localparam logic [4:0] E_AUD1   = 5'd4;
  localparam logic [4:0] E_AUD2   = 5'd5;
  localparam logic [4:0] E_AUD3   = 5'd6;
  localparam logic [4:0] E_H0     = 5'd7;
  localparam logic [4:0] E_H1     = 5'd8;
  localparam logic [4:0] E_H2     = 5'd9;
  localparam logic [4:0] E_H3     = 5'd10;
  localparam logic [4:0] E_H4     = 5'd11;
  localparam logic [4:0] E_H5     = 5'd12;
  localparam logic [4:0] E_H6     = 5'd13;
  localparam logic [4:0] E_H7     = 5'd14;
  localparam logic [4:0] E_H8     = 5'd15;
  localparam logic [4:0] E_H9     = 5'd16;
  localparam logic [4:0] E_MB     = 5'd17;
  localparam logic [4:0] E_SLEND  = 5'd18;
  localparam logic [4:0] E_SLWAIT = 5'd19;
  localparam logic [4:0] E_FLUSH  = 5'd20;
  localparam logic [4:0] E_DONE   = 5'd21;
  localparam logic [4:0] E_DRAIN  = 5'd22;
  localparam logic [4:0] E_SKR    = 5'd23;   // mb_skip_run of the trailing skipped macroblocks

  // Fetch sequencer states.
  localparam logic [1:0] F_IDLE = 2'd0;
  localparam logic [1:0] F_WAIT = 2'd1;
  localparam logic [1:0] F_RUN  = 2'd2;

  logic [4:0]        st;
  logic [1:0]        ft;
  logic              cfg_ok;
  logic              cfg_ok_q;

  // Slice bookkeeping.
  logic [7:0]        d_q;
  logic [7:0]        d_rem;
  logic [7:0]        slice_idx;
  logic [7:0]        rows_left;
  logic [7:0]        skip_left;
  logic [31:0]       mbn;

  // Pointers of the rebuilt-picture writer and the fetch sequencer.
  logic [ADDR_W-1:0] in_ptr;
  logic [ADDR_W-1:0] ry_ptr;
  logic [ADDR_W-1:0] ru_ptr;
  logic [ADDR_W-1:0] f_ptr;
  logic [15:0]       me_left;           // macroblocks of the band the search has not started yet
  logic [7:0]        me_x;              // column of the next macroblock to search
  logic              me_ch;             // strip half of that macroblock
  logic              xh;                // prediction bank the search fills next
  logic              xc;                // prediction bank stage A uses next
  logic [1:0]        xfull;
  logic signed [13:0] xmv_x [2];
  logic signed [13:0] xmv_y [2];
  logic              me_active;
  logic              me_start;
  logic              me_idle;
  logic              me_done;
  logic signed [5:0] me_vx;
  logic signed [5:0] me_vy;
  logic              srch_idle;
  logic              strip_req;
  logic              win_req;
  logic              win_go;
  logic              ref_busy;          // the window loader owns the AR and R channels
  logic              ref_err;
  logic              ref_arvalid;
  logic              ref_arready;
  logic [ADDR_W-1:0] ref_araddr;
  logic [7:0]        ref_arlen;
  logic              ref_rready;
  logic              ref_rvalid;
  logic              pred_we;
  logic [REF_AW-1:0] pred_addr;
  logic [127:0]      pred_data;
  logic              me_src_req;
  logic [RAM_AW-1:0] me_src_addr;
  logic              me_src_gnt;
  logic              a_src_lock;
  // Bench visibility of the search stage (candidate results); not used by the engine.
  /* verilator lint_off UNUSEDSIGNAL */
  logic              dbg_ev_v;
  logic signed [5:0] dbg_ev_vx;
  logic signed [5:0] dbg_ev_vy;
  logic [18:0]       dbg_ev_sad;
  logic [16:0]       dbg_best_cost;
  logic [2:0]        rd_arsize_u;
  logic [1:0]        rd_arburst_u;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [RAM_AW-1:0] me_src_base;
  logic              rd_arvalid;
  logic              rd_arready;
  logic [ADDR_W-1:0] rd_araddr;
  logic [7:0]        rd_arlen;
  logic              rd_rready;
  logic              rd_rvalid;
  logic [REF_AW-1:0] ref_bank_c;
  logic [REF_AW-1:0] ref_bank_f;
  logic              a_ref_en;
  logic [REF_AW-1:0] a_ref_addr;
  logic [127:0]      a_ref_data;
  logic              a_inter;
  logic              a_skip;
  logic [3:0]        a_cbp4;
  logic signed [15:0] a_mvdx;
  logic signed [15:0] a_mvdy;
  logic [15:0]       b_skip_run;
  logic              a_av_tr;
  logic [7:0]        f_x;
  logic [7:0]        f_rows_left;
  logic              fetch_go;
  logic              fh;
  logic              ch;
  logic [1:0]        sfull;
  logic [3:0]        n_f;

  // Macroblock pipeline control: source bank cb, coefficient banks ab (stage A) and bb (stage B), rebuilt banks
  // rb (stage A) and rr (writer); a_x / a_first_row track the macroblock position of stage A.
  logic              ab;
  logic              bb;
  logic              rb;
  logic              rr;
  logic [1:0]        cfull;
  logic [1:0]        rfull;
  logic              src_busy;
  logic [2:0]        mb_out;
  logic [7:0]        a_x;
  logic              a_first_row;
  logic              a_last;
  logic              a_go;
  logic              b_go;
  logic              b_run;
  logic              rec_run;
  logic              rec_start;
  logic [1:0]        bi_mode [2];
  logic [1:0]        bi_cm [2];
  logic [1:0]        bi_cbpc [2];
  logic              bi_cbpl [2];
  logic              bi_pcm [2];
  logic              bi_inter [2];
  logic              bi_skip [2];
  logic [3:0]        bi_cbp4 [2];
  logic signed [15:0] bi_mvdx [2];
  logic signed [15:0] bi_mvdy [2];
  logic [7:0]        bi_x [2];
  logic              bi_avt [2];
  logic              bi_avl [2];

  // Statistics.
  logic [31:0]       gap;
  logic              first_seen;

  // Packer command mux.
  logic              seq_valid;
  logic [2:0]        seq_op;
  logic [31:0]       seq_val;
  logic [5:0]        seq_len;
  logic              seq_kind;
  logic              mx_valid;
  logic [2:0]        mx_op;
  logic [31:0]       mx_val;
  logic [5:0]        mx_len;
  logic              mx_kind;
  logic              pk_in_ready;
  logic              pk_cmd_valid;
  logic              pk_cmd_ready;
  logic [2:0]        pk_cmd_op;
  logic [31:0]       pk_cmd_val;
  logic [5:0]        pk_cmd_len;
  logic              pk_cmd_kind;

  // Macroblock coder wires: stage A, stage B (CAVLC), the I_PCM coder, the rebuilt-picture writer.
  logic              a_busy;
  logic              a_done;
  logic [1:0]        a_i16;
  logic [1:0]        a_cm;
  logic [1:0]        a_cbpc;
  logic              a_cbpl;
  logic              a_pcm;
  logic              b_busy;
  logic              b_done;
  logic              coder_busy;
  logic              cod_valid;
  logic [2:0]        cod_op;
  logic [31:0]       cod_val;
  logic [5:0]        cod_len;
  logic              cav_valid;
  logic [2:0]        cav_op;
  logic [31:0]       cav_val;
  logic [5:0]        cav_len;
  logic              a_src_en;
  logic [RAM_AW-1:0] a_src_addr;
  logic              src_rd_en;
  logic [RAM_AW-1:0] src_rd_addr;
  logic [127:0]      src_rd_data;
  logic              reb_we;
  logic [REC_AW-1:0] reb_waddr;
  logic [31:0]       reb_wdata;
  logic              cof_we;
  logic [CRAM_AW-1:0] cof_waddr;
  logic [47:0]       cof_wdata;
  logic              cofa_rd_en;
  logic [CRAM_AW-1:0] cofa_raddr;
  logic [47:0]       cofa_rdata;
  logic              cofb_rd_en;
  logic [CRAM_AW-1:0] cofb_raddr;
  logic [47:0]       cofb_rdata;
  // The rebuilt-picture writer's busy output is not needed: the engine waits for its done pulse.
  /* verilator lint_off UNUSEDSIGNAL */
  logic              rec_busy;
  /* verilator lint_on UNUSEDSIGNAL */
  logic              rec_done;
  logic              rec_ram_en;
  logic [REC_AW-1:0] rec_ram_addr;
  logic [31:0]       rec_ram_data;
  logic              rd_start;
  logic              rd_busy;
  logic              rd_done;
  logic              rd_ram_we;
  logic [RAM_AW-1:0] rd_ram_addr;
  logic [127:0]      rd_ram_data;
  logic              rd_err;
  logic              wm_err;

  // Packer output and ring writer.
  logic              pk_o_valid;
  logic              pk_o_ready;
  logic [7:0]        pk_o_data;
  logic              pk_o_first;
  logic              pk_o_last;
  logic              pk_o_kind;
  logic              pk_idle;
  logic              nal_done;
  logic              ring_idle;

  // Write master wires.
  logic              rg_valid;
  logic [ADDR_W-1:0] rg_addr;
  logic [3:0]        rg_len;
  logic              rg_pop;
  logic              rg_w_valid;
  logic [127:0]      rg_w_data;
  logic [15:0]       rg_w_strb;
  logic              rg_w_pop;
  logic              ix_valid;
  logic [ADDR_W-1:0] ix_addr;
  logic [127:0]      ix_data;
  logic              ix_ack;
  logic              rc_valid;
  logic [ADDR_W-1:0] rc_addr;
  logic [3:0]        rc_len;
  logic              rc_pop;
  logic              rc_w_valid;
  logic [127:0]      rc_w_data;
  logic              rc_w_pop;
  logic              ev_b_ring;
  logic              ev_b_idx;
  // The rebuilt-picture write response needs no action beyond the master's outstanding count.
  /* verilator lint_off UNUSEDSIGNAL */
  logic              ev_b_rec;
  /* verilator lint_on UNUSEDSIGNAL */
  logic              wm_busy;
  logic [4:0]        wm_out;
  logic [RAM_AW-1:0] bank_base_c;
  logic [RAM_AW-1:0] bank_base_f;
  logic              strip_last;
  logic [REC_AW-1:0] reb_base_a;
  logic [REC_AW-1:0] reb_base_r;
  logic [CRAM_AW-1:0] cof_base_a;
  logic [CRAM_AW-1:0] cof_base_b;
  logic              slice_is_last;
  logic [7:0]        rows_next;

  assign busy        = (st != E_IDLE);
  assign m_arid      = ref_busy ? ID_W'(1) : '0;
  // AR and R channels: the strip DMA and the reference DMA own them one at a time.
  assign m_arvalid   = ref_busy ? ref_arvalid : rd_arvalid;
  assign m_araddr    = ref_busy ? ref_araddr  : rd_araddr;
  assign m_arlen     = ref_busy ? ref_arlen   : rd_arlen;
  assign m_arsize    = 3'd4;
  assign m_arburst   = 2'b01;
  assign rd_arready  = m_arready && !ref_busy;
  assign ref_arready = m_arready && ref_busy;
  assign m_rready    = ref_busy ? ref_rready : rd_rready;
  assign rd_rvalid   = m_rvalid && !ref_busy;
  assign ref_rvalid  = m_rvalid && ref_busy;
  assign err_axi     = rd_err || ref_err || wm_err;
  // Strip buffer address of macroblock a_x of the current strip half (bank pitch BANK_WORDS) and of the half being fetched.
  assign bank_base_c = RAM_AW'(BANK_WORDS * RD_STRIP_MB) * RAM_AW'(ch) + RAM_AW'(BANK_WORDS) * RAM_AW'(a_x[MI-1:0]);
  assign bank_base_f = RAM_AW'(BANK_WORDS * RD_STRIP_MB) * RAM_AW'(fh);
  // Strip buffer address of the macroblock the search starts next.
  assign me_src_base = RAM_AW'(BANK_WORDS * RD_STRIP_MB) * RAM_AW'(me_ch) + RAM_AW'(BANK_WORDS) * RAM_AW'(me_x[MI-1:0]);
  // The macroblock stage A has just finished (bi_x of the coefficient bank it filled) is the last of its strip.
  assign strip_last  = (bi_x[ab][MI-1:0] == MI'(RD_STRIP_MB - 1)) || (bi_x[ab] == (cfg_mb_w - 8'd1));
  assign n_f         = ((cfg_mb_w - f_x) > 8'(RD_STRIP_MB)) ? 4'(RD_STRIP_MB) : 4'(cfg_mb_w - f_x);
  assign slice_is_last = (slice_idx == (eng_slices - 8'd1));
  assign rows_next   = d_q + (((slice_idx + 8'd1) < d_rem) ? 8'd1 : 8'd0);
  assign reb_base_a  = rb ? REC_AW'(REC_BANK) : REC_AW'(0);
  assign reb_base_r  = rr ? REC_AW'(REC_BANK) : REC_AW'(0);
  assign cof_base_a  = ab ? CRAM_AW'(COEF_BANK) : CRAM_AW'(0);
  assign cof_base_b  = bb ? CRAM_AW'(COEF_BANK) : CRAM_AW'(0);
  assign ref_bank_c  = xc ? REF_AW'(REF_BANK) : REF_AW'(0);
  assign ref_bank_f  = xh ? REF_AW'(REF_BANK) : REF_AW'(0);
  assign a_av_tr     = !a_first_row && ((a_x + 8'd1) < cfg_mb_w);
  assign coder_busy  = a_busy || b_busy;

  // Stage A starts on a full source bank when the coefficient and rebuilt banks of its turn are free. Stage B starts
  // on a full coefficient bank. Both are combinational decisions that act in the clock they are made.
  assign a_go  = (st == E_MB) && !a_last && !src_busy && sfull[ch] && !cfull[ab] && !rfull[rb] && (!cfg_p || xfull[xc]);
  // The strip fetch starts when its half is free and no other read is running or about to start.
  assign strip_req = (ft == F_WAIT) && (f_rows_left != 8'd0) && !sfull[fh] && !rd_busy && !rd_start && !ref_busy;
  assign win_go    = win_req && !rd_busy && !rd_start && !ref_busy && !strip_req;
  assign b_go  = ((st == E_MB) || (st == E_DRAIN)) && !b_run && cfull[bb];
  assign cod_valid = cav_valid;
  assign cod_op    = cav_op;
  assign cod_val   = cav_val;
  assign cod_len   = cav_len;
  assign rec_start = !rec_run && rfull[rr] && (st != E_IDLE);

  // Configuration check: sizes in range, bases and strides aligned, strides wide enough.
  always_comb begin
    cfg_ok = 1'b1;
    if ((cfg_mb_w == 8'd0) || (cfg_mb_w > 8'(MAX_MB_W))) cfg_ok = 1'b0;
    if ((cfg_mb_h == 8'd0) || (cfg_mb_h > 8'(MAX_MB_H))) cfg_ok = 1'b0;
    if ((band_rows == 8'd0) || (({1'b0, band_first_row} + {1'b0, band_rows}) > {1'b0, cfg_mb_h})) cfg_ok = 1'b0;
    if ((eng_slices == 8'd0) || (eng_slices > band_rows)) cfg_ok = 1'b0;
    if (cfg_qp > 6'd51) cfg_ok = 1'b0;
    if ((cfg_log2_fn < 5'd4) || (cfg_log2_fn > 5'd16)) cfg_ok = 1'b0;
    if ((cfg_in_base[MI+4:0] != '0) || (cfg_in_stride[MI+4:0] != '0)) cfg_ok = 1'b0;   // multiples of the strip burst bytes
    if ((cfg_ry_base[7:0] != 8'd0) || (cfg_ru_base[6:0] != 7'd0)) cfg_ok = 1'b0;      // tile-aligned: 256 B luma, 128 B chroma
    if ((cfg_ring_base[3:0] != 4'd0) || (cfg_ring_size[3:0] != 4'd0) || (cfg_ring_size < 32'd1024)) cfg_ok = 1'b0;
    if ((cfg_idx_base[6:0] != 7'd0) || (cfg_idx_entries == 32'd0)) cfg_ok = 1'b0;     // 128-byte index records
    if (cfg_p && cfg_idr) cfg_ok = 1'b0;                                              // a P picture is not an IDR picture
    if (cfg_p && ((cfg_refy_base[7:0] != 8'd0) || (cfg_refu_base[6:0] != 7'd0))) cfg_ok = 1'b0;   // reference tiles aligned
    if (cfg_in_stride < ADDR_W'({cfg_mb_w, 5'd0})) cfg_ok = 1'b0;
  end

  // The check is registered: the configuration registers are written well before the start write.
  always_ff @(posedge clk) begin
    if (!resetn) cfg_ok_q <= 1'b0;
    else         cfg_ok_q <= cfg_ok;
  end

  assign err_cfg  = start && !busy && !cfg_ok_q;
  assign err_busy = start && busy;

  // ---------------------------------------------------------------------------
  // Sequencer command generation
  // ---------------------------------------------------------------------------
  always_comb begin
    seq_valid = 1'b1;
    seq_op    = PK_FIELD;
    seq_val   = '0;
    seq_len   = 6'd0;
    seq_kind  = NAL_SLICE;
    case (st)
      E_AUD0: begin seq_op = PK_START; seq_kind = NAL_AUD; end
      E_AUD1: begin seq_op = PK_FIELD; seq_val = 32'h09; seq_len = 6'd8; end
      E_AUD2: begin seq_op = PK_FIELD; seq_val = 32'd7; seq_len = 6'd3; end
      E_AUD3: begin seq_op = PK_END; end
      E_H0:   begin seq_op = PK_START; seq_kind = NAL_SLICE; end
      E_H1: begin
        seq_op  = PK_FIELD;
        seq_val = cfg_idr ? 32'h65 : 32'h61;
        seq_len = 6'd8;
      end
      E_H2: begin seq_op = PK_UE; seq_val = mbn; end
      E_H3: begin seq_op = PK_UE; seq_val = cfg_p ? 32'(SLICE_TYPE_P_ALL) : 32'd7; end
      E_H4: begin seq_op = PK_UE; seq_val = 32'd0; end
      E_H5: begin seq_op = PK_FIELD; seq_val = {16'd0, cfg_frame_num}; seq_len = {1'b0, cfg_log2_fn}; end
      E_H6: begin seq_op = PK_UE; seq_val = {16'd0, cfg_idr_pic_id}; end
      // IDR: no_output_of_prior_pics_flag, long_term_reference_flag. P: num_ref_idx_active_override_flag,
      // ref_pic_list_modification_flag_l0, adaptive_ref_pic_marking_mode_flag. Non-IDR I: adaptive_ref_pic_marking_mode_flag.
      E_H7: begin seq_op = PK_FIELD; seq_val = 32'd0; seq_len = cfg_idr ? 6'd2 : (cfg_p ? 6'd3 : 6'd1); end
      E_H8: begin seq_op = PK_SE; seq_val = 32'(signed'({1'b0, cfg_qp}) - 7'sd26); end
      E_H9: begin seq_op = PK_UE; seq_val = 32'd1; end
      E_SKR:  begin seq_op = PK_UE; seq_val = 32'(b_skip_run); end
      E_SLEND: begin seq_op = PK_END; end
      default: seq_valid = 1'b0;
    endcase
  end

  assign mx_valid = seq_valid || cod_valid;
  assign mx_op    = cod_valid ? cod_op  : seq_op;
  assign mx_val   = cod_valid ? cod_val : seq_val;
  assign mx_len   = cod_valid ? cod_len : seq_len;
  assign mx_kind  = seq_kind;

  // One register stage between the command sources and the packer (timing): a command moves into it when it is
  // empty or the packer takes its content; the sequencer and the coder see that as their ready.
  assign pk_in_ready = !pk_cmd_valid || pk_cmd_ready;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      pk_cmd_valid <= 1'b0;
      pk_cmd_op    <= PK_FIELD;
      pk_cmd_val   <= '0;
      pk_cmd_len   <= '0;
      pk_cmd_kind  <= NAL_AUD;
    end else if (pk_in_ready) begin
      pk_cmd_valid <= mx_valid;
      pk_cmd_op    <= mx_op;
      pk_cmd_val   <= mx_val;
      pk_cmd_len   <= mx_len;
      pk_cmd_kind  <= mx_kind;
    end
  end

  // ---------------------------------------------------------------------------
  // Sequencer, fetch sequencer, statistics
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      st             <= E_IDLE;
      ft             <= F_IDLE;
      done           <= 1'b0;
      d_q            <= '0;
      d_rem          <= '0;
      slice_idx      <= '0;
      rows_left      <= '0;
      skip_left      <= '0;
      mbn            <= '0;
      in_ptr         <= '0;
      ry_ptr         <= '0;
      ru_ptr         <= '0;
      f_ptr          <= '0;
      f_x            <= '0;
      f_rows_left    <= '0;
      me_left        <= '0;
      me_x           <= '0;
      me_ch          <= 1'b0;
      me_active      <= 1'b0;
      xh             <= 1'b0;
      xc             <= 1'b0;
      xfull          <= '0;
      xmv_x[0]       <= '0;
      xmv_x[1]       <= '0;
      xmv_y[0]       <= '0;
      xmv_y[1]       <= '0;
      fetch_go       <= 1'b0;
      fh             <= 1'b0;
      ch             <= 1'b0;
      ab             <= 1'b0;
      bb             <= 1'b0;
      rb             <= 1'b0;
      rr             <= 1'b0;
      sfull          <= '0;
      cfull          <= '0;
      rfull          <= '0;
      src_busy       <= 1'b0;
      mb_out         <= '0;
      a_x            <= '0;
      a_first_row    <= 1'b1;
      a_last         <= 1'b0;
      b_run          <= 1'b0;
      rec_run        <= 1'b0;
      for (int i = 0; i < 2; i++) begin
        bi_mode[i] <= '0;
        bi_cm[i]   <= '0;
        bi_cbpc[i] <= '0;
        bi_cbpl[i] <= 1'b0;
        bi_pcm[i]  <= 1'b0;
        bi_inter[i] <= 1'b0;
        bi_skip[i] <= 1'b0;
        bi_cbp4[i] <= '0;
        bi_mvdx[i] <= '0;
        bi_mvdy[i] <= '0;
        bi_x[i]    <= '0;
        bi_avt[i]  <= 1'b0;
        bi_avl[i]  <= 1'b0;
      end
      rd_start       <= 1'b0;
      gap            <= '0;
      first_seen     <= 1'b0;
      st_mb_count    <= '0;
      st_slice_pulse <= 1'b0;
      st_cyc_last    <= '0;
      st_cyc_max     <= '0;
      st_pic_cyc     <= '0;
      st_rd_cyc      <= '0;
      st_pk_cyc      <= '0;
      st_wr_cyc      <= '0;
    end else begin
      done           <= 1'b0;
      fetch_go       <= 1'b0;
      rd_start       <= 1'b0;
      st_slice_pulse <= 1'b0;
      gap            <= gap + 32'd1;

      if (busy) begin
        st_pic_cyc <= st_pic_cyc + 32'd1;
        if (rd_busy || ref_busy) st_rd_cyc <= st_rd_cyc + 32'd1;
        if (coder_busy) st_pk_cyc <= st_pk_cyc + 32'd1;
        if (wm_busy)    st_wr_cyc <= st_wr_cyc + 32'd1;
      end

      // Sequencer.
      case (st)
        E_IDLE: begin
          if (start && cfg_ok_q) begin
            st          <= E_DIV;
            d_q         <= '0;
            d_rem       <= band_rows;
            slice_idx   <= '0;
            skip_left   <= band_first_row;
            mbn         <= '0;
            in_ptr      <= cfg_in_base;
            ry_ptr      <= cfg_ry_base;
            ru_ptr      <= cfg_ru_base;
            xc          <= 1'b0;
            xh          <= 1'b0;
            xfull       <= '0;
            me_active   <= 1'b0;
            ch          <= 1'b0;
            ab          <= 1'b0;
            bb          <= 1'b0;
            rb          <= 1'b0;
            rr          <= 1'b0;
            sfull       <= '0;
            cfull       <= '0;
            rfull       <= '0;
            src_busy    <= 1'b0;
            mb_out      <= '0;
            a_x         <= '0;
            a_first_row <= 1'b1;
            a_last      <= 1'b0;
            b_run       <= 1'b0;
            rec_run     <= 1'b0;
            first_seen  <= 1'b0;
            gap         <= '0;
            st_mb_count <= '0;
            st_cyc_last <= '0;
            st_cyc_max  <= '0;
            st_pic_cyc  <= '0;
            st_rd_cyc   <= '0;
            st_pk_cyc   <= '0;
            st_wr_cyc   <= '0;
          end
        end
        E_DIV: begin
          if (d_rem >= eng_slices) begin
            d_rem <= d_rem - eng_slices;
            d_q   <= d_q + 8'd1;
          end else begin
            st        <= E_PTR;
            rows_left <= d_q + ((d_rem != 8'd0) ? 8'd1 : 8'd0);
          end
        end
        E_PTR: begin
          if (skip_left != 8'd0) begin
            skip_left <= skip_left - 8'd1;
            in_ptr    <= in_ptr + {cfg_in_stride[ADDR_W-5:0], 4'd0};
            // A skipped macroblock row advances the tile pointers by mb_w tiles.
            ry_ptr    <= ry_ptr + ADDR_W'({cfg_mb_w, 8'd0});
            ru_ptr    <= ru_ptr + ADDR_W'({cfg_mb_w, 7'd0});
            mbn       <= mbn + 32'(cfg_mb_w);
          end else begin
            fetch_go <= 1'b1;
            st       <= EMIT_AUD ? E_AUD0 : E_H0;
          end
        end
        E_AUD0, E_AUD1, E_AUD2, E_AUD3, E_H0, E_H1, E_H2, E_H3, E_H4, E_H5, E_H7, E_H8, E_H9, E_SKR, E_SLEND: begin
          if (pk_in_ready) begin
            case (st)
              E_AUD0:  st <= E_AUD1;
              E_AUD1:  st <= E_AUD2;
              E_AUD2:  st <= E_AUD3;
              E_AUD3:  st <= E_H0;
              E_H0:    st <= E_H1;
              E_H1:    st <= E_H2;
              E_H2:    st <= E_H3;
              E_H3:    st <= E_H4;
              E_H4:    st <= E_H5;
              E_H5:    st <= cfg_idr ? E_H6 : E_H7;
              E_H7:    st <= E_H8;
              E_H8:    st <= E_H9;
              E_H9:    st <= E_MB;
              E_SKR:   st <= E_SLEND;
              default: st <= E_SLWAIT;
            endcase
          end
        end
        E_H6: begin
          if (pk_in_ready) st <= E_H7;
        end
        E_MB: begin
          if (a_go) begin
            src_busy    <= 1'b1;
            gap         <= 32'd1;
            first_seen  <= 1'b1;
            mbn         <= mbn + 32'd1;
            bi_x[ab]    <= a_x;
            bi_avt[ab]  <= !a_first_row;
            bi_avl[ab]  <= (a_x != 8'd0);
            if (first_seen) begin
              st_cyc_last <= gap;
              if (gap > st_cyc_max) st_cyc_max <= gap;
            end
            if (a_x == (cfg_mb_w - 8'd1)) begin
              a_x         <= '0;
              a_first_row <= 1'b0;
              rows_left   <= rows_left - 8'd1;
              if (rows_left == 8'd1) a_last <= 1'b1;
            end else begin
              a_x <= a_x + 8'd1;
            end
          end
          if (a_last) st <= E_DRAIN;
        end
        E_DRAIN: begin
          if (mb_out == 3'd0) st <= (cfg_p && (b_skip_run != 16'd0)) ? E_SKR : E_SLEND;
        end
        E_SLWAIT: begin
          if (nal_done) begin
            st_slice_pulse <= 1'b1;
            if (slice_is_last) begin
              st <= E_FLUSH;
            end else begin
              slice_idx <= slice_idx + 8'd1;
              rows_left <= rows_next;
              st        <= E_H0;
            end
          end
        end
        E_FLUSH: begin
          if (ring_idle && pk_idle && (wm_out == 5'd0) && !wm_busy && (ft == F_IDLE) && srch_idle && !me_active && !ref_busy &&
              (mb_out == 3'd0) && !rec_run &&
              !rfull[0] && !rfull[1]) st <= E_DONE;
        end
        E_DONE: begin
          done <= 1'b1;
          st   <= E_IDLE;
        end
        default: st <= E_IDLE;
      endcase

      // Slice start: stage A's row flags.
      if (st == E_H1) begin
        a_first_row <= 1'b1;
        a_last      <= 1'b0;
      end

      // Stage A finished a macroblock: the rebuilt bank is complete, the source bank is released and the coefficient bank
      // (levels, or the I_PCM sample words) goes to stage B.
      if (a_done) begin
        rfull[rb]    <= 1'b1;
        rb           <= ~rb;
        if (strip_last) begin
          sfull[ch] <= 1'b0;
          ch        <= ~ch;
        end
        src_busy     <= 1'b0;
        if (cfg_p) begin
          xfull[xc]  <= 1'b0;
          xc         <= ~xc;
        end
        cfull[ab]    <= 1'b1;
        bi_inter[ab] <= a_inter;
        bi_skip[ab]  <= a_skip;
        bi_cbp4[ab]  <= a_cbp4;
        bi_mvdx[ab]  <= a_mvdx;
        bi_mvdy[ab]  <= a_mvdy;
        bi_mode[ab]  <= a_i16;
        bi_cm[ab]    <= a_cm;
        bi_cbpc[ab]  <= a_cbpc;
        bi_cbpl[ab]  <= a_cbpl;
        bi_pcm[ab]   <= a_pcm;
        ab           <= ~ab;
      end
      if (b_go) b_run <= 1'b1;
      if (b_done) begin
        b_run  <= 1'b0;
        cfull[bb] <= 1'b0;
        bb     <= ~bb;
      end
      if (b_done) st_mb_count <= st_mb_count + 32'd1;
      mb_out <= mb_out + {2'b00, a_go} - {2'b00, b_done};

      // Rebuilt-picture writer: starts on a full rebuilt bank, advances the tile pointers by one macroblock's tiles when
      // it is done (tiles are in raster order of the picture).
      if (rec_start) rec_run <= 1'b1;
      if (rec_done) begin
        rec_run   <= 1'b0;
        rfull[rr] <= 1'b0;
        rr        <= ~rr;
        ry_ptr    <= ry_ptr + ADDR_W'(REC_LUMA_TILE_BYTES);
        ru_ptr    <= ru_ptr + ADDR_W'(REC_CHROMA_TILE_BYTES);
      end

      // Fetch sequencer: fills the free strip half with the next strip of the row (n_f macroblocks from f_x).
      case (ft)
        F_IDLE: begin
          if (fetch_go) begin
            f_ptr       <= in_ptr;
            f_x         <= '0;
            f_rows_left <= band_rows;
            fh          <= 1'b0;
            ft          <= F_WAIT;
          end
        end
        F_WAIT: begin
          if (f_rows_left == 8'd0) begin
            ft <= F_IDLE;
          end else if (strip_req) begin
            rd_start <= 1'b1;
            ft       <= F_RUN;
          end
        end
        F_RUN: begin
          if (rd_done) begin
            sfull[fh] <= 1'b1;
            fh        <= ~fh;
            ft        <= F_WAIT;
            if ((f_x + 8'(RD_STRIP_MB)) >= cfg_mb_w) begin
              f_x         <= '0;
              f_ptr       <= f_ptr + {cfg_in_stride[ADDR_W-5:0], 4'd0};
              f_rows_left <= f_rows_left - 8'd1;
            end else begin
              f_x <= f_x + 8'(RD_STRIP_MB);
            end
          end
        end
        default: ft <= F_IDLE;
      endcase

      // Motion search sequencer (P pictures): one macroblock of the band per start, in raster order, into the free prediction bank once the
      // macroblock's source strip is in the strip buffer. The search stage fills the bank and reports the vector.
      if (fetch_go && cfg_p) begin
        me_left   <= 16'(band_rows) * 16'(cfg_mb_w);
        me_x      <= '0;
        me_ch     <= 1'b0;
        me_active <= 1'b1;
      end
      if (me_start) begin
        me_left <= me_left - 16'd1;
        if (((me_x[MI-1:0] == MI'(RD_STRIP_MB - 1)) && (RD_STRIP_MB > 1)) || (me_x == (cfg_mb_w - 8'd1))) me_ch <= ~me_ch;
        if (me_x == (cfg_mb_w - 8'd1)) me_x <= '0;
        else                           me_x <= me_x + 8'd1;
        if (me_left == 16'd1) me_active <= 1'b0;
      end
      if (me_done) begin
        xmv_x[xh] <= 14'(me_vx) * 14'sd4;
        xmv_y[xh] <= 14'(me_vy) * 14'sd4;
        xfull[xh] <= 1'b1;
        xh        <= ~xh;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Datapath instances
  // ---------------------------------------------------------------------------
  rtlnet_h264_rd_dma #(.ADDR_W(ADDR_W), .RAM_AW(RAM_AW), .NMB(RD_STRIP_MB)) u_rd_dma (
    .clk(clk), .resetn(resetn),
    .start(rd_start), .mb_addr(f_ptr + ADDR_W'({f_x, 5'd0})), .stride(cfg_in_stride), .n_mb(n_f), .dst_base(bank_base_f),
    .busy(rd_busy), .done(rd_done),
    .araddr(rd_araddr), .arlen(rd_arlen), .arsize(rd_arsize_u), .arburst(rd_arburst_u), .arvalid(rd_arvalid),
    .arready(rd_arready),
    .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rvalid(rd_rvalid), .rready(rd_rready),
    .ram_wr_en(rd_ram_we), .ram_wr_addr(rd_ram_addr), .ram_wr_data(rd_ram_data),
    .err_resp(rd_err)
  );

  // Motion search stage (phase 2c-2): window loader, search, prediction generator (documentation section 16). It starts with the picture
  // (fetch_go of a P picture) and takes the strip buffer's read port in the clocks stage A leaves free.
  assign me_start     = me_active && (me_left != 16'd0) && me_idle && !xfull[xh] && sfull[me_ch];
  assign me_src_gnt   = !a_src_en && !a_src_lock;

  rtlnet_h264_search #(
    .ADDR_W(ADDR_W), .MAX_MB_W(MAX_MB_W), .SR(SR), .WIN_KB(WIN_KB), .MV_LINE_KB(MV_LINE_KB), .SRC_AW(RAM_AW), .REF_AW(REF_AW),
    .RAM_STYLE(RAM_STYLE)
  ) u_search (
    .clk(clk), .resetn(resetn),
    .pic_start(fetch_go && cfg_p), .cfg_mb_w(cfg_mb_w), .cfg_mb_h(cfg_mb_h), .band_first_row(band_first_row), .band_rows(band_rows),
    .ref_y_base(cfg_refy_base), .ref_u_base(cfg_refu_base), .qp(cfg_qp),
    .win_req(win_req), .win_go(win_go), .win_busy(ref_busy), .win_araddr(ref_araddr), .win_arlen(ref_arlen), .win_arvalid(ref_arvalid),
    .win_arready(ref_arready), .win_rdata(m_rdata), .win_rresp(m_rresp), .win_rvalid(ref_rvalid), .win_rready(ref_rready),
    .err_resp(ref_err),
    .mb_start(me_start), .mb_src_base(me_src_base), .mb_pred_base(ref_bank_f), .mb_idle(me_idle), .mb_done(me_done),
    .mb_vx(me_vx), .mb_vy(me_vy),
    .src_rd_req(me_src_req), .src_rd_addr(me_src_addr), .src_rd_gnt(me_src_gnt), .src_rd_data(src_rd_data),
    .pred_we(pred_we), .pred_addr(pred_addr), .pred_data(pred_data),
    .idle(srch_idle),
    .dbg_ev_v(dbg_ev_v), .dbg_ev_vx(dbg_ev_vx), .dbg_ev_vy(dbg_ev_vy), .dbg_ev_sad(dbg_ev_sad), .dbg_best_cost(dbg_best_cost)
  );

  // Prediction buffer (two banks of 32 words, 24 used): written by the search stage, read by stage A.
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(REF_AW), .READ_LATENCY(1)) u_ref_ram (
    .wr_clk(clk), .wr_en(pred_we), .wr_addr(pred_addr), .wr_data(pred_data),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(a_ref_en), .rd_addr(a_ref_addr), .rd_data(a_ref_data)
  );

  // Strip buffer (two halves of RD_STRIP_MB macroblock banks): written by the read DMA, read by stage A, and by the search stage for the
  // source rows of its macroblock (only in a clock stage A does not read).
  assign src_rd_en   = a_src_en || (me_src_req && me_src_gnt);
  assign src_rd_addr = a_src_en ? a_src_addr : me_src_addr;
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(RAM_AW), .READ_LATENCY(1)) u_mb_ram (
    .wr_clk(clk), .wr_en(rd_ram_we), .wr_addr(rd_ram_addr), .wr_data(rd_ram_data),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(src_rd_en), .rd_addr(src_rd_addr), .rd_data(src_rd_data)
  );

  // Rebuilt macroblock buffer (two banks of 96 words of 4 samples): written by stage A, read by the picture writer.
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(32), .ADDR_W(REC_AW), .READ_LATENCY(1)) u_reb_ram (
    .wr_clk(clk), .wr_en(reb_we), .wr_addr(reb_waddr), .wr_data(reb_wdata),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(rec_ram_en), .rd_addr(rec_ram_addr), .rd_data(rec_ram_data)
  );

  // Coefficient buffer (two banks): two copies written together, one read back by stage A, one read by stage B.
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(48), .ADDR_W(CRAM_AW), .READ_LATENCY(1)) u_cof_a (
    .wr_clk(clk), .wr_en(cof_we), .wr_addr(cof_waddr), .wr_data(cof_wdata),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(cofa_rd_en), .rd_addr(cofa_raddr), .rd_data(cofa_rdata)
  );
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(48), .ADDR_W(CRAM_AW), .READ_LATENCY(1)) u_cof_b (
    .wr_clk(clk), .wr_en(cof_we), .wr_addr(cof_waddr), .wr_data(cof_wdata),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(cofb_rd_en), .rd_addr(cofb_raddr), .rd_data(cofb_rdata)
  );

  rtlnet_h264_mb_enc #(
    .MAX_MB_W(MAX_MB_W), .LINE_KB(LINE_KB), .RAM_STYLE(RAM_STYLE), .SRC_AW(RAM_AW), .REC_AW(REC_AW), .CRAM_AW(CRAM_AW),
    .REF_AW(REF_AW), .MV_LINE_KB(MV_LINE_KB)
  ) u_mb_enc (
    .clk(clk), .resetn(resetn),
    .start(a_go), .pcm_mode(cfg_mb_pcm), .p_pic(cfg_p), .mb_x(a_x), .av_top(!a_first_row), .av_left(a_x != 8'd0),
    .av_tr(a_av_tr), .qp(cfg_qp),
    .src_base(bank_base_c), .reb_base(reb_base_a), .coef_base(cof_base_a), .ref_base(ref_bank_c),
    .mv_in_x(xmv_x[xc]), .mv_in_y(xmv_y[xc]), .src_lock(a_src_lock),
    .busy(a_busy), .done(a_done),
    .o_i16_mode(a_i16), .o_chroma_mode(a_cm), .o_cbp_chroma(a_cbpc), .o_cbp_luma(a_cbpl), .o_pcm(a_pcm),
    .o_inter(a_inter), .o_skip(a_skip), .o_cbp4(a_cbp4), .o_mvd_x(a_mvdx), .o_mvd_y(a_mvdy),
    .ref_rd_en(a_ref_en), .ref_rd_addr(a_ref_addr), .ref_rd_data(a_ref_data),
    .src_rd_en(a_src_en), .src_rd_addr(a_src_addr), .src_rd_data(src_rd_data),
    .reb_we(reb_we), .reb_waddr(reb_waddr), .reb_wdata(reb_wdata),
    .cof_we(cof_we), .cof_waddr(cof_waddr), .cof_wdata(cof_wdata),
    .cof_rd_en(cofa_rd_en), .cof_raddr(cofa_raddr), .cof_rdata(cofa_rdata)
  );

  rtlnet_h264_mb_cavlc #(.MAX_MB_W(MAX_MB_W), .RAM_STYLE(RAM_STYLE), .CRAM_AW(CRAM_AW)) u_cavlc (
    .clk(clk), .resetn(resetn),
    .start(b_go), .mb_x(bi_x[bb]), .av_top(bi_avt[bb]), .av_left(bi_avl[bb]), .pcm(bi_pcm[bb]), .i16_mode(bi_mode[bb]),
    .cbp_chroma(bi_cbpc[bb]), .cbp_luma(bi_cbpl[bb]), .chroma_mode(bi_cm[bb]), .cbase(cof_base_b),
    .p_slice(cfg_p), .skip(bi_skip[bb]), .inter(bi_inter[bb]), .cbp_luma4(bi_cbp4[bb]), .mvd_x(bi_mvdx[bb]), .mvd_y(bi_mvdy[bb]),
    .slice_start(st == E_H0), .skip_run(b_skip_run),
    .busy(b_busy), .done(b_done),
    .cram_rd_en(cofb_rd_en), .cram_rd_addr(cofb_raddr), .cram_rd_data(cofb_rdata),
    .cmd_valid(cav_valid), .cmd_ready(pk_in_ready), .cmd_op(cav_op), .cmd_val(cav_val), .cmd_len(cav_len)
  );

  rtlnet_h264_recon_wr #(.ADDR_W(ADDR_W), .RAM_AW(REC_AW), .RAM_STYLE(RAM_STYLE)) u_recon (
    .clk(clk), .resetn(resetn),
    .start(rec_start), .base(reb_base_r), .y_addr(ry_ptr), .c_addr(ru_ptr), .busy(rec_busy), .done(rec_done),
    .ram_rd_en(rec_ram_en), .ram_rd_addr(rec_ram_addr), .ram_rd_data(rec_ram_data),
    .rc_valid(rc_valid), .rc_addr(rc_addr), .rc_len(rc_len), .rc_pop(rc_pop),
    .rc_w_valid(rc_w_valid), .rc_w_data(rc_w_data), .rc_w_pop(rc_w_pop)
  );

  rtlnet_h264_bitpack u_pack (
    .clk(clk), .resetn(resetn),
    .cmd_valid(pk_cmd_valid), .cmd_ready(pk_cmd_ready), .cmd_op(pk_cmd_op), .cmd_val(pk_cmd_val),
    .cmd_len(pk_cmd_len), .cmd_kind(pk_cmd_kind),
    .o_valid(pk_o_valid), .o_ready(pk_o_ready), .o_data(pk_o_data), .o_first(pk_o_first), .o_last(pk_o_last),
    .o_kind(pk_o_kind), .idle(pk_idle)
  );

  rtlnet_h264_ring_wr #(.ADDR_W(ADDR_W), .FIFO_KB(FIFO_KB), .RAM_STYLE(RAM_STYLE)) u_ring (
    .clk(clk), .resetn(resetn),
    .ring_base(cfg_ring_base), .ring_size(cfg_ring_size), .idx_base(cfg_idx_base), .idx_entries(cfg_idx_entries),
    .ring_reset(ring_reset),
    .rptr_wr(rptr_wr), .rptr_val(rptr_val), .idx_rptr_wr(idx_rptr_wr), .idx_rptr_val(idx_rptr_val),
    .u_valid(pk_o_valid), .u_ready(pk_o_ready), .u_data(pk_o_data), .u_first(pk_o_first), .u_last(pk_o_last),
    .u_kind(pk_o_kind),
    .m_pic(cfg_pic_no), .m_slice({8'd0, slice_base + slice_idx}), .m_nslices({8'd0, eng_slices}), .m_qp({2'b00, cfg_qp}), .m_type(cfg_p ? SLICE_TYPE_P_ALL : SLICE_TYPE_I_ALL),
    .m_idr(cfg_idr), .m_last_slice(slice_is_last),
    .rg_valid(rg_valid), .rg_addr(rg_addr), .rg_len(rg_len), .rg_pop(rg_pop),
    .rg_w_valid(rg_w_valid), .rg_w_data(rg_w_data), .rg_w_strb(rg_w_strb), .rg_w_pop(rg_w_pop),
    .ix_valid(ix_valid), .ix_addr(ix_addr), .ix_data(ix_data), .ix_ack(ix_ack),
    .ev_b_ring_i(ev_b_ring), .ev_b_idx_i(ev_b_idx),
    .ring_wptr(ring_wptr), .ring_fill(ring_fill), .idx_wptr(idx_wptr), .idx_fill_o(idx_fill),
    .nal_done(nal_done), .ring_stall(ring_stall), .idle(ring_idle), .err_rptr(err_rptr)
  );

  rtlnet_h264_wr_master #(.ADDR_W(ADDR_W), .ID_W(ID_W)) u_wr (
    .clk(clk), .resetn(resetn),
    .rg_valid(rg_valid), .rg_addr(rg_addr), .rg_len(rg_len), .rg_pop(rg_pop),
    .rg_w_valid(rg_w_valid), .rg_w_data(rg_w_data), .rg_w_strb(rg_w_strb), .rg_w_pop(rg_w_pop),
    .ix_valid(ix_valid), .ix_addr(ix_addr), .ix_data(ix_data), .ix_ack(ix_ack),
    .rc_valid(rc_valid), .rc_addr(rc_addr), .rc_len(rc_len), .rc_pop(rc_pop),
    .rc_w_valid(rc_w_valid), .rc_w_data(rc_w_data), .rc_w_pop(rc_w_pop),
    .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize), .awburst(m_awburst),
    .awvalid(m_awvalid), .awready(m_awready),
    .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
    .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
    .ev_b_ring(ev_b_ring), .ev_b_idx(ev_b_idx), .ev_b_rec(ev_b_rec), .err_resp(wm_err),
    .busy(wm_busy), .outstanding(wm_out)
  );

  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (resetn && m_arvalid && m_arready) begin
      if ((m_arburst != 2'b01) || (m_arsize != 3'd4) || (m_arlen > 8'd15) ||
          (((m_araddr & 32'hFFF) + (({24'd0, m_arlen} + 32'd1) << 4)) > 32'h1000)) begin
        $error("rtlnet_h264_engine: illegal AR burst addr 0x%0h len %0d size %0d burst %0d", m_araddr, m_arlen,
               m_arsize, m_arburst);
      end
    end
  end
  // synthesis translate_on

endmodule
