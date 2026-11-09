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
//     ue(v) = 1. nal_ref_idc is 3; nal_unit_type is 5 (IDR) or 1.
//   * Macroblock pipeline: the fetch sequencer fills two macroblock-buffer banks through the read DMA in raster
//     order while the macroblock coder (I_PCM) and the rebuilt-picture writer drain the other bank. A bank is
//     released when both are done. The coder is the throughput limit: one sample byte per clock.
//   * Band: band_first_row and band_rows select the macroblock rows of this engine (the whole picture for
//     NUM_ENGINES = 1); eng_slices slices of whole rows are coded inside the band, numbered from slice_base in
//     the picture. Only the engine with EMIT_AUD writes the access unit delimiter.
//   * Statistics (cleared at start): cycles between successive macroblock starts (last, max), cycles of
//     the whole picture, and busy cycles of the read DMA, the coder and the write master.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk (all logic).
// -----------------------------------------------------------------------------
module rtlnet_h264_engine #(
  parameter int    ADDR_W    = 32,
  parameter int    ID_W      = 4,
  parameter int    MAX_MB_W  = 120,
  parameter int    MAX_MB_H  = 68,
  parameter int    MB_BUF_KB = 1,
  parameter int    FIFO_KB   = 1,
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

  // Picture configuration, clk domain, stable while busy. Strides and base addresses in bytes.
  input  logic [7:0]        cfg_mb_w,
  input  logic [7:0]        cfg_mb_h,
  input  logic [7:0]        eng_slices,
  input  logic [7:0]        slice_base,
  input  logic [ADDR_W-1:0] cfg_in_base,
  input  logic [ADDR_W-1:0] cfg_in_stride,
  input  logic [ADDR_W-1:0] cfg_ry_base,
  input  logic [ADDR_W-1:0] cfg_ry_stride,
  input  logic [ADDR_W-1:0] cfg_ru_base,
  input  logic [ADDR_W-1:0] cfg_rv_base,
  input  logic [ADDR_W-1:0] cfg_rc_stride,
  input  logic [5:0]        cfg_qp,
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

  // Pointers of the consumer (coder and rebuilt writer) and the fetch sequencer.
  logic [ADDR_W-1:0] in_ptr;
  logic [ADDR_W-1:0] ry_ptr;
  logic [ADDR_W-1:0] ru_ptr;
  logic [ADDR_W-1:0] rv_ptr;
  logic [7:0]        c_x;
  logic [ADDR_W-1:0] f_ptr;
  logic [7:0]        f_x;
  logic [7:0]        f_rows_left;
  logic              fetch_go;
  logic              fb;
  logic              cb;
  logic [1:0]        full;
  logic              mb_run;
  logic              cd_f;
  logic              rc_f;
  logic              coder_start;
  logic              rec_start;
  logic              mb_fin;

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

  // Coder and DMA wires.
  logic              coder_busy;
  logic              coder_done;
  logic              cod_valid;
  logic [2:0]        cod_op;
  logic [31:0]       cod_val;
  logic [5:0]        cod_len;
  logic              cod_ram_en;
  logic [RAM_AW-1:0] cod_ram_addr;
  logic [127:0]      cod_ram_data;
  // The rebuilt-picture writer's busy output is not needed: the engine waits for its done pulse.
  /* verilator lint_off UNUSEDSIGNAL */
  logic              rec_busy;
  /* verilator lint_on UNUSEDSIGNAL */
  logic              rec_done;
  logic              rec_ram_en;
  logic [RAM_AW-1:0] rec_ram_addr;
  logic [127:0]      rec_ram_data;
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
  logic [127:0]      rc_data;
  logic [15:0]       rc_strb;
  logic              rc_ack;
  logic              ev_b_ring;
  logic              ev_b_idx;
  // The rebuilt-picture write response needs no action beyond the master's outstanding count.
  /* verilator lint_off UNUSEDSIGNAL */
  logic              ev_b_rec;
  /* verilator lint_on UNUSEDSIGNAL */
  logic              wm_busy;
  logic [4:0]        wm_out;
  logic [ADDR_W-1:0] y_addr;
  logic [ADDR_W-1:0] u_addr;
  logic [ADDR_W-1:0] v_addr;
  logic [RAM_AW-1:0] bank_base_c;
  logic [RAM_AW-1:0] bank_base_f;
  logic              slice_is_last;
  logic [7:0]        rows_next;

  assign busy        = (st != E_IDLE);
  assign m_arid      = '0;
  assign err_axi     = rd_err || wm_err;
  assign bank_base_c = cb ? RAM_AW'(BANK_WORDS) : RAM_AW'(0);
  assign bank_base_f = fb ? RAM_AW'(BANK_WORDS) : RAM_AW'(0);
  assign y_addr      = ry_ptr + ADDR_W'({c_x, 4'b0000});
  assign u_addr      = ru_ptr + ADDR_W'({c_x, 3'b000});
  assign v_addr      = rv_ptr + ADDR_W'({c_x, 3'b000});
  assign slice_is_last = (slice_idx == (eng_slices - 8'd1));
  assign rows_next   = d_q + (((slice_idx + 8'd1) < d_rem) ? 8'd1 : 8'd0);
  assign mb_fin      = mb_run && (cd_f || coder_done) && (rc_f || rec_done);

  // Configuration check: sizes in range, bases and strides aligned, strides wide enough.
  always_comb begin
    cfg_ok = 1'b1;
    if ((cfg_mb_w == 8'd0) || (cfg_mb_w > 8'(MAX_MB_W))) cfg_ok = 1'b0;
    if ((cfg_mb_h == 8'd0) || (cfg_mb_h > 8'(MAX_MB_H))) cfg_ok = 1'b0;
    if ((band_rows == 8'd0) || (({1'b0, band_first_row} + {1'b0, band_rows}) > {1'b0, cfg_mb_h})) cfg_ok = 1'b0;
    if ((eng_slices == 8'd0) || (eng_slices > band_rows)) cfg_ok = 1'b0;
    if (cfg_qp > 6'd51) cfg_ok = 1'b0;
    if ((cfg_log2_fn < 5'd4) || (cfg_log2_fn > 5'd16)) cfg_ok = 1'b0;
    if ((cfg_in_base[4:0] != 5'd0) || (cfg_in_stride[4:0] != 5'd0)) cfg_ok = 1'b0;
    if ((cfg_ry_base[3:0] != 4'd0) || (cfg_ry_stride[3:0] != 4'd0) || (cfg_ru_base[3:0] != 4'd0) ||
        (cfg_rv_base[3:0] != 4'd0) || (cfg_rc_stride[3:0] != 4'd0)) cfg_ok = 1'b0;
    if ((cfg_ring_base[3:0] != 4'd0) || (cfg_ring_size[3:0] != 4'd0) || (cfg_ring_size < 32'd1024)) cfg_ok = 1'b0;
    if ((cfg_idx_base[3:0] != 4'd0) || (cfg_idx_entries == 32'd0)) cfg_ok = 1'b0;
    if (cfg_in_stride < ADDR_W'({cfg_mb_w, 5'd0})) cfg_ok = 1'b0;
    if (cfg_ry_stride < ADDR_W'({cfg_mb_w, 4'd0})) cfg_ok = 1'b0;
    if (cfg_rc_stride < ADDR_W'({cfg_mb_w, 3'd0})) cfg_ok = 1'b0;
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
      E_H3: begin seq_op = PK_UE; seq_val = 32'd7; end
      E_H4: begin seq_op = PK_UE; seq_val = 32'd0; end
      E_H5: begin seq_op = PK_FIELD; seq_val = {16'd0, cfg_frame_num}; seq_len = {1'b0, cfg_log2_fn}; end
      E_H6: begin seq_op = PK_UE; seq_val = {16'd0, cfg_idr_pic_id}; end
      E_H7: begin seq_op = PK_FIELD; seq_val = 32'd0; seq_len = cfg_idr ? 6'd2 : 6'd1; end
      E_H8: begin seq_op = PK_SE; seq_val = 32'(signed'({1'b0, cfg_qp}) - 7'sd26); end
      E_H9: begin seq_op = PK_UE; seq_val = 32'd1; end
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
      rv_ptr         <= '0;
      c_x            <= '0;
      f_ptr          <= '0;
      f_x            <= '0;
      f_rows_left    <= '0;
      fetch_go       <= 1'b0;
      fb             <= 1'b0;
      cb             <= 1'b0;
      full           <= '0;
      mb_run         <= 1'b0;
      cd_f           <= 1'b0;
      rc_f           <= 1'b0;
      coder_start    <= 1'b0;
      rec_start      <= 1'b0;
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
      coder_start    <= 1'b0;
      rec_start      <= 1'b0;
      rd_start       <= 1'b0;
      st_slice_pulse <= 1'b0;
      gap            <= gap + 32'd1;

      if (busy) begin
        st_pic_cyc <= st_pic_cyc + 32'd1;
        if (rd_busy)    st_rd_cyc <= st_rd_cyc + 32'd1;
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
            rv_ptr      <= cfg_rv_base;
            c_x         <= '0;
            cb          <= 1'b0;
            full        <= '0;
            mb_run      <= 1'b0;
            cd_f        <= 1'b0;
            rc_f        <= 1'b0;
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
            ry_ptr    <= ry_ptr + {cfg_ry_stride[ADDR_W-5:0], 4'd0};
            ru_ptr    <= ru_ptr + {cfg_rc_stride[ADDR_W-4:0], 3'd0};
            rv_ptr    <= rv_ptr + {cfg_rc_stride[ADDR_W-4:0], 3'd0};
            mbn       <= mbn + 32'(cfg_mb_w);
          end else begin
            fetch_go <= 1'b1;
            st       <= EMIT_AUD ? E_AUD0 : E_H0;
          end
        end
        E_AUD0, E_AUD1, E_AUD2, E_AUD3, E_H0, E_H1, E_H2, E_H3, E_H4, E_H5, E_H7, E_H8, E_H9, E_SLEND: begin
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
              default: st <= E_SLWAIT;
            endcase
          end
        end
        E_H6: begin
          if (pk_in_ready) st <= E_H7;
        end
        E_MB: begin
          if (!mb_run && full[cb]) begin
            coder_start <= 1'b1;
            rec_start   <= 1'b1;
            mb_run      <= 1'b1;
            gap         <= 32'd1;
            first_seen  <= 1'b1;
            if (first_seen) begin
              st_cyc_last <= gap;
              if (gap > st_cyc_max) st_cyc_max <= gap;
            end
          end
          if (coder_done) cd_f <= 1'b1;
          if (rec_done)   rc_f <= 1'b1;
          if (mb_fin) begin
            mb_run      <= 1'b0;
            cd_f        <= 1'b0;
            rc_f        <= 1'b0;
            full[cb]    <= 1'b0;
            cb          <= ~cb;
            mbn         <= mbn + 32'd1;
            st_mb_count <= st_mb_count + 32'd1;
            if (c_x == (cfg_mb_w - 8'd1)) begin
              c_x    <= '0;
              ry_ptr <= ry_ptr + {cfg_ry_stride[ADDR_W-5:0], 4'd0};
              ru_ptr <= ru_ptr + {cfg_rc_stride[ADDR_W-4:0], 3'd0};
              rv_ptr <= rv_ptr + {cfg_rc_stride[ADDR_W-4:0], 3'd0};
              rows_left <= rows_left - 8'd1;
              if (rows_left == 8'd1) st <= E_SLEND;
            end else begin
              c_x <= c_x + 8'd1;
            end
          end
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
          if (ring_idle && pk_idle && (wm_out == 5'd0) && !wm_busy && (ft == F_IDLE)) st <= E_DONE;
        end
        E_DONE: begin
          done <= 1'b1;
          st   <= E_IDLE;
        end
        default: st <= E_IDLE;
      endcase

      // Fetch sequencer: fills the free bank with the next macroblock.
      case (ft)
        F_IDLE: begin
          if (fetch_go) begin
            f_ptr       <= in_ptr;
            f_x         <= '0;
            f_rows_left <= band_rows;
            fb          <= 1'b0;
            ft          <= F_WAIT;
          end
        end
        F_WAIT: begin
          if (f_rows_left == 8'd0) begin
            ft <= F_IDLE;
          end else if (!full[fb] && !rd_busy && !rd_start) begin
            rd_start <= 1'b1;
            ft       <= F_RUN;
          end
        end
        F_RUN: begin
          if (rd_done) begin
            full[fb] <= 1'b1;
            fb       <= ~fb;
            ft       <= F_WAIT;
            if (f_x == (cfg_mb_w - 8'd1)) begin
              f_x         <= '0;
              f_ptr       <= f_ptr + {cfg_in_stride[ADDR_W-5:0], 4'd0};
              f_rows_left <= f_rows_left - 8'd1;
            end else begin
              f_x <= f_x + 8'd1;
            end
          end
        end
        default: ft <= F_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Datapath instances
  // ---------------------------------------------------------------------------
  rtlnet_h264_rd_dma #(.ADDR_W(ADDR_W), .RAM_AW(RAM_AW)) u_rd_dma (
    .clk(clk), .resetn(resetn),
    .start(rd_start), .mb_addr(f_ptr + ADDR_W'({f_x, 5'd0})), .stride(cfg_in_stride), .dst_base(bank_base_f),
    .busy(rd_busy), .done(rd_done),
    .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize), .arburst(m_arburst), .arvalid(m_arvalid),
    .arready(m_arready),
    .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rvalid(m_rvalid), .rready(m_rready),
    .ram_wr_en(rd_ram_we), .ram_wr_addr(rd_ram_addr), .ram_wr_data(rd_ram_data),
    .err_resp(rd_err)
  );

  // Two copies of the macroblock buffer: one read by the coder, one by the rebuilt-picture writer.
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(RAM_AW), .READ_LATENCY(1)) u_mb_ram_cod (
    .wr_clk(clk), .wr_en(rd_ram_we), .wr_addr(rd_ram_addr), .wr_data(rd_ram_data),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(cod_ram_en), .rd_addr(cod_ram_addr), .rd_data(cod_ram_data)
  );
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(RAM_AW), .READ_LATENCY(1)) u_mb_ram_rec (
    .wr_clk(clk), .wr_en(rd_ram_we), .wr_addr(rd_ram_addr), .wr_data(rd_ram_data),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(rec_ram_en), .rd_addr(rec_ram_addr), .rd_data(rec_ram_data)
  );

  rtlnet_h264_mb_pcm #(.RAM_AW(RAM_AW)) u_coder (
    .clk(clk), .resetn(resetn),
    .start(coder_start), .base(bank_base_c), .busy(coder_busy), .done(coder_done),
    .ram_rd_en(cod_ram_en), .ram_rd_addr(cod_ram_addr), .ram_rd_data(cod_ram_data),
    .cmd_valid(cod_valid), .cmd_ready(pk_in_ready), .cmd_op(cod_op), .cmd_val(cod_val), .cmd_len(cod_len)
  );

  rtlnet_h264_recon_wr #(.ADDR_W(ADDR_W), .RAM_AW(RAM_AW)) u_recon (
    .clk(clk), .resetn(resetn),
    .start(rec_start), .base(bank_base_c), .y_addr(y_addr), .u_addr(u_addr), .v_addr(v_addr),
    .y_stride(cfg_ry_stride), .c_stride(cfg_rc_stride), .busy(rec_busy), .done(rec_done),
    .ram_rd_en(rec_ram_en), .ram_rd_addr(rec_ram_addr), .ram_rd_data(rec_ram_data),
    .req_valid(rc_valid), .req_addr(rc_addr), .req_data(rc_data), .req_strb(rc_strb), .req_ack(rc_ack)
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
    .m_pic(cfg_pic_no), .m_slice({8'd0, slice_base + slice_idx}), .m_nslices({8'd0, eng_slices}), .m_qp({2'b00, cfg_qp}), .m_type(SLICE_TYPE_I_ALL),
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
    .rc_valid(rc_valid), .rc_addr(rc_addr), .rc_data(rc_data), .rc_strb(rc_strb), .rc_ack(rc_ack),
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
