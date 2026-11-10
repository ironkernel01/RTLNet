// -----------------------------------------------------------------------------
// File: rtlnet_h264_enc_regs.sv
// Purpose: register file of rtlnet_h264_top: ID/VERSION/CAPS header, control and status with the done and
//   error flags, picture, frame-buffer, ring and index-ring configuration, and the counters and
//   cycle statistics of the engine.
// Overview:
//   * Strobe interface of rtlnet_axil_slave: a write strobe carries a full 32-bit word; a read strobe is
//     answered with a registered read mux, data valid the clock after reg_rd_en. Undefined offsets
//     read 0; writes to them are ignored. Offsets are defined in driver/rtlnet_h264_enc.h and mirrored here.
//   * CTRL: bit 0 START (self-clearing strobe), bit 1 RING_RESET (self-clearing strobe), bit 8 IRQ_EN.
//     STATUS: bit 0 BUSY, bit 1 DONE (set when a picture is complete, write 1 to clear), bit 2 ERR
//     (set by any error pulse, write 1 to clear), bit 3 RING_STALL (live). ERR_CODE holds the
//     first error code since the last ERR clear. irq is high while IRQ_EN and (DONE or ERR).
//   * Configuration registers are read back as written. They are written while the engine is idle; the
//     read pointers RING_RPTR and IDX_RPTR are also written while it runs (consumption).
//   * Engine windows: with NUM_ENGINES > 1 the per-engine registers (RING_WPTR, RING_RPTR, RING_FILL, IDX_WPTR, IDX_RPTR,
//     IDX_FILL, MB_COUNT and the cycle statistics) of engine e are at 0x100 * e plus their window-0 offset; window 0 is
//     engine 0. Each engine has its own compressed ring and index ring: the configured ring is split into equal parts.
//   * Counters (PIC_COUNT, SLICE_COUNT) are 32-bit, wrap and reset to 0; PIC_COUNT[15:0] is the picture number
//     stamped into the index entries.
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-09-2026: initial version.
//   * 11-10-2026: tiled rebuilt picture: RY_BASE and RU_BASE are the luma and chroma tile bases, the stride registers and
//     RV_BASE are reserved; index records are 128 bytes.
// Clocks: clk (all logic).
// -----------------------------------------------------------------------------
module rtlnet_h264_enc_regs #(
  parameter int MAX_MB_W     = 120,
  parameter int MAX_MB_H     = 68,
  parameter int NUM_ENGINES  = 1
)(
  // Register clock and synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Register strobes from rtlnet_axil_slave, clk domain: one full-word write per reg_wr_en clock;
  // reg_rd_data is due the clock after reg_rd_en.
  input  logic        reg_wr_en,
  input  logic [11:0] reg_wr_addr,
  input  logic [31:0] reg_wr_data,
  input  logic        reg_rd_en,
  input  logic [11:0] reg_rd_addr,
  output logic [31:0] reg_rd_data,

  // Control to the engines, clk domain: start and ring_reset pulse for one clock; the configuration is
  // stable while the engine runs.
  output logic        start,
  output logic        ring_reset,
  output logic [7:0]  cfg_mb_w,
  output logic [7:0]  cfg_mb_h,
  output logic [7:0]  cfg_slices,
  output logic [31:0] cfg_in_base,
  output logic [31:0] cfg_in_stride,
  output logic [31:0] cfg_ry_base,
  output logic [31:0] cfg_ru_base,
  output logic [5:0]  cfg_qp,
  output logic        cfg_mb_pcm,
  output logic [15:0] cfg_frame_num,
  output logic [15:0] cfg_idr_pic_id,
  output logic        cfg_idr,
  output logic [4:0]  cfg_log2_fn,
  output logic [15:0] cfg_pic_no,
  output logic [31:0] cfg_ring_base,
  output logic [31:0] cfg_ring_size,
  output logic [31:0] cfg_idx_base,
  output logic [31:0] cfg_idx_entries,
  output logic [NUM_ENGINES-1:0]    rptr_wr,
  output logic [NUM_ENGINES*32-1:0] rptr_val,
  output logic [NUM_ENGINES-1:0]    idx_rptr_wr,
  output logic [NUM_ENGINES*32-1:0] idx_rptr_val,

  // Engine status and events, clk domain: busy level, one-clock pulses done, slice_pulse and the error
  // pulses, and the statistics and pointer values.
  input  logic        busy,
  input  logic        done,
  input  logic        slice_pulse,
  input  logic        err_cfg,
  input  logic        err_axi,
  input  logic        err_rptr,
  input  logic        err_busy,
  input  logic [NUM_ENGINES-1:0]    ring_stall,
  input  logic [NUM_ENGINES*32-1:0] ring_wptr,
  input  logic [NUM_ENGINES*32-1:0] ring_fill,
  input  logic [NUM_ENGINES*32-1:0] idx_wptr,
  input  logic [NUM_ENGINES*32-1:0] idx_fill,
  input  logic [NUM_ENGINES*32-1:0] st_mb_count,
  input  logic [NUM_ENGINES*32-1:0] st_cyc_last,
  input  logic [NUM_ENGINES*32-1:0] st_cyc_max,
  input  logic [NUM_ENGINES*32-1:0] st_pic_cyc,
  input  logic [NUM_ENGINES*32-1:0] st_rd_cyc,
  input  logic [NUM_ENGINES*32-1:0] st_pk_cyc,
  input  logic [NUM_ENGINES*32-1:0] st_wr_cyc,

  // Interrupt, clk domain: level, high while IRQ_EN and (DONE or ERR) are set.
  output logic        irq
);

  import rtlnet_pkg::*;
  import rtlnet_h264_pkg::*;

  // Register map: mirrors cores/rtlnet_h264_enc/driver/rtlnet_h264_enc.h.
  localparam logic [11:0] REG_ID          = 12'h000;
  localparam logic [11:0] REG_VERSION     = 12'h004;
  localparam logic [11:0] REG_CAPS        = 12'h008;
  localparam logic [11:0] REG_CTRL        = 12'h00C;
  localparam logic [11:0] REG_STATUS      = 12'h010;
  localparam logic [11:0] REG_ERR_CODE    = 12'h014;
  localparam logic [11:0] REG_MB_W        = 12'h020;
  localparam logic [11:0] REG_MB_H        = 12'h024;
  localparam logic [11:0] REG_SLICES      = 12'h028;
  localparam logic [11:0] REG_QP          = 12'h02C;
  localparam logic [11:0] REG_FRAME_NUM   = 12'h030;
  localparam logic [11:0] REG_IDR_PIC_ID  = 12'h034;
  localparam logic [11:0] REG_PIC_CFG     = 12'h038;
  localparam logic [11:0] REG_MB_MODE     = 12'h03C;
  localparam logic [11:0] REG_IN_BASE     = 12'h040;
  localparam logic [11:0] REG_IN_STRIDE   = 12'h044;
  localparam logic [11:0] REG_RY_BASE     = 12'h048;   // rebuilt picture luma tile base (256 B per macroblock)
  // 0x04C, 0x054 and 0x058 (the former strides and the Cr base) are reserved: they read 0 and ignore writes.
  localparam logic [11:0] REG_RU_BASE     = 12'h050;   // rebuilt picture chroma tile base (Cb then Cr, 128 B per macroblock)
  localparam logic [11:0] REG_RING_BASE   = 12'h060;
  localparam logic [11:0] REG_RING_SIZE   = 12'h064;
  localparam logic [11:0] REG_RING_WPTR   = 12'h068;
  localparam logic [11:0] REG_RING_RPTR   = 12'h06C;
  localparam logic [11:0] REG_RING_FILL   = 12'h070;
  localparam logic [11:0] REG_IDX_BASE    = 12'h078;
  localparam logic [11:0] REG_IDX_ENTRIES = 12'h07C;
  localparam logic [11:0] REG_IDX_WPTR    = 12'h080;
  localparam logic [11:0] REG_IDX_RPTR    = 12'h084;
  localparam logic [11:0] REG_IDX_FILL    = 12'h088;
  localparam logic [11:0] REG_PIC_COUNT   = 12'h090;
  localparam logic [11:0] REG_SLICE_COUNT = 12'h094;
  localparam logic [11:0] REG_MB_COUNT    = 12'h098;
  localparam logic [11:0] REG_CYC_LAST    = 12'h09C;
  localparam logic [11:0] REG_CYC_MAX     = 12'h0A0;
  localparam logic [11:0] REG_PIC_CYC     = 12'h0A4;
  localparam logic [11:0] REG_RD_CYC      = 12'h0A8;
  localparam logic [11:0] REG_PK_CYC      = 12'h0AC;
  localparam logic [11:0] REG_WR_CYC      = 12'h0B0;

  localparam int CTRL_START_BIT      = 0;
  localparam int CTRL_RING_RESET_BIT = 1;
  localparam int CTRL_IRQ_EN_BIT     = 8;
  localparam int STATUS_BUSY_BIT     = 0;
  localparam int STATUS_DONE_BIT     = 1;
  localparam int STATUS_ERR_BIT      = 2;
  localparam int STATUS_STALL_BIT    = 3;

  localparam logic [31:0] CORE_ID      = id4("H", "2", "6", "4");
  localparam logic [31:0] CORE_VERSION = 32'h1110_2026;
  // CAPS: [7:0] MAX_MB_W, [15:8] MAX_MB_H, [19:16] NUM_ENGINES.
  localparam logic [31:0] CORE_CAPS    = {12'd0, 4'(NUM_ENGINES), 8'(MAX_MB_H), 8'(MAX_MB_W)};

  logic        irq_en;
  logic        done_flag;
  logic        err_flag;
  logic [7:0]  err_code;
  logic [31:0] pic_count;
  logic [31:0] slice_count;
  logic [31:0] rptr_shadow [NUM_ENGINES];
  logic [31:0] idx_rptr_shadow [NUM_ENGINES];
  logic [31:0] eng_word;
  logic        eng_hit;
  logic        err_any;
  logic [7:0]  err_new;
  logic [31:0] status_word;

  assign err_any = err_cfg || err_axi || err_rptr || err_busy;
  assign err_new = err_cfg ? ERR_CONFIG : (err_busy ? ERR_BUSY : (err_rptr ? ERR_RPTR : ERR_AXI));
  assign irq     = irq_en && (done_flag || err_flag);
  assign cfg_pic_no = pic_count[15:0];

  always_comb begin
    status_word                  = '0;
    status_word[STATUS_BUSY_BIT]  = busy;
    status_word[STATUS_DONE_BIT]  = done_flag;
    status_word[STATUS_ERR_BIT]   = err_flag;
    status_word[STATUS_STALL_BIT] = |ring_stall;
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      start           <= 1'b0;
      ring_reset      <= 1'b0;
      irq_en          <= 1'b0;
      done_flag       <= 1'b0;
      err_flag        <= 1'b0;
      err_code        <= ERR_NONE;
      pic_count       <= '0;
      slice_count     <= '0;
      cfg_mb_w        <= '0;
      cfg_mb_h        <= '0;
      cfg_slices      <= 8'd1;
      cfg_qp          <= 6'(PIC_INIT_QP);
      cfg_mb_pcm      <= 1'b0;
      cfg_frame_num   <= '0;
      cfg_idr_pic_id  <= '0;
      cfg_idr         <= 1'b1;
      cfg_log2_fn     <= 5'd4;
      cfg_in_base     <= '0;
      cfg_in_stride   <= '0;
      cfg_ry_base     <= '0;
      cfg_ru_base     <= '0;
      cfg_ring_base   <= '0;
      cfg_ring_size   <= '0;
      cfg_idx_base    <= '0;
      cfg_idx_entries <= '0;
      rptr_wr         <= '0;
      rptr_val        <= '0;
      idx_rptr_wr     <= '0;
      idx_rptr_val    <= '0;
      for (int e = 0; e < NUM_ENGINES; e++) begin
        rptr_shadow[e]     <= '0;
        idx_rptr_shadow[e] <= '0;
      end
    end else begin
      start       <= 1'b0;
      ring_reset  <= 1'b0;
      rptr_wr     <= '0;
      idx_rptr_wr <= '0;

      if (done) begin
        done_flag <= 1'b1;
        pic_count <= pic_count + 32'd1;
      end
      if (slice_pulse) slice_count <= slice_count + 32'd1;
      if (err_any) begin
        if (!err_flag) err_code <= err_new;
        err_flag <= 1'b1;
      end

      if (reg_wr_en && (reg_wr_addr[11:8] != 4'd0)) begin
        // Engine windows 1..NUM_ENGINES-1: the read pointers of that engine (offsets as in window 0).
        for (int e = 1; e < NUM_ENGINES; e++) begin
          if (reg_wr_addr[11:8] == 4'(e)) begin
            if (reg_wr_addr[7:0] == REG_RING_RPTR[7:0]) begin
              rptr_wr[e]           <= 1'b1;
              rptr_val[e*32 +: 32] <= reg_wr_data;
              rptr_shadow[e]       <= reg_wr_data;
            end
            if (reg_wr_addr[7:0] == REG_IDX_RPTR[7:0]) begin
              idx_rptr_wr[e]           <= 1'b1;
              idx_rptr_val[e*32 +: 32] <= reg_wr_data;
              idx_rptr_shadow[e]       <= reg_wr_data;
            end
          end
        end
      end else if (reg_wr_en) begin
        case (reg_wr_addr)
          REG_CTRL: begin
            start      <= reg_wr_data[CTRL_START_BIT];
            ring_reset <= reg_wr_data[CTRL_RING_RESET_BIT];
            irq_en     <= reg_wr_data[CTRL_IRQ_EN_BIT];
            if (reg_wr_data[CTRL_RING_RESET_BIT]) begin
              for (int e = 0; e < NUM_ENGINES; e++) begin
                rptr_shadow[e]     <= '0;
                idx_rptr_shadow[e] <= '0;
              end
            end
          end
          REG_STATUS: begin
            if (reg_wr_data[STATUS_DONE_BIT] && !done) done_flag <= 1'b0;
            if (reg_wr_data[STATUS_ERR_BIT] && !err_any) begin
              err_flag <= 1'b0;
              err_code <= '0;
            end
          end
          REG_MB_W:        cfg_mb_w        <= reg_wr_data[7:0];
          REG_MB_H:        cfg_mb_h        <= reg_wr_data[7:0];
          REG_SLICES:      cfg_slices      <= reg_wr_data[7:0];
          REG_QP:          cfg_qp          <= reg_wr_data[5:0];
          REG_MB_MODE:     cfg_mb_pcm      <= reg_wr_data[0];
          REG_FRAME_NUM:   cfg_frame_num   <= reg_wr_data[15:0];
          REG_IDR_PIC_ID:  cfg_idr_pic_id  <= reg_wr_data[15:0];
          REG_PIC_CFG: begin
            cfg_idr     <= reg_wr_data[0];
            cfg_log2_fn <= reg_wr_data[12:8];
          end
          REG_IN_BASE:     cfg_in_base     <= reg_wr_data;
          REG_IN_STRIDE:   cfg_in_stride   <= reg_wr_data;
          REG_RY_BASE:     cfg_ry_base     <= reg_wr_data;
          REG_RU_BASE:     cfg_ru_base     <= reg_wr_data;
          REG_RING_BASE:   cfg_ring_base   <= reg_wr_data;
          REG_RING_SIZE:   cfg_ring_size   <= reg_wr_data;
          REG_RING_RPTR: begin
            rptr_wr[0]     <= 1'b1;
            rptr_val[31:0] <= reg_wr_data;
            rptr_shadow[0] <= reg_wr_data;
          end
          REG_IDX_BASE:    cfg_idx_base    <= reg_wr_data;
          REG_IDX_ENTRIES: cfg_idx_entries <= reg_wr_data;
          REG_IDX_RPTR: begin
            idx_rptr_wr[0]     <= 1'b1;
            idx_rptr_val[31:0] <= reg_wr_data;
            idx_rptr_shadow[0] <= reg_wr_data;
          end
          default: begin
          end
        endcase
      end
    end
  end

  // Per-engine registers: the offsets of window 0 in window e select engine e (window 0 is engine 0).
  always_comb begin
    eng_word = '0;
    eng_hit  = 1'b0;
    for (int e = 0; e < NUM_ENGINES; e++) begin
      if (reg_rd_addr[11:8] == 4'(e)) begin
        eng_hit = 1'b1;
        case (reg_rd_addr[7:0])
          REG_RING_WPTR[7:0]: eng_word = ring_wptr[e*32 +: 32];
          REG_RING_RPTR[7:0]: eng_word = rptr_shadow[e];
          REG_RING_FILL[7:0]: eng_word = ring_fill[e*32 +: 32];
          REG_IDX_WPTR[7:0]:  eng_word = idx_wptr[e*32 +: 32];
          REG_IDX_RPTR[7:0]:  eng_word = idx_rptr_shadow[e];
          REG_IDX_FILL[7:0]:  eng_word = idx_fill[e*32 +: 32];
          REG_MB_COUNT[7:0]:  eng_word = st_mb_count[e*32 +: 32];
          REG_CYC_LAST[7:0]:  eng_word = st_cyc_last[e*32 +: 32];
          REG_CYC_MAX[7:0]:   eng_word = st_cyc_max[e*32 +: 32];
          REG_PIC_CYC[7:0]:   eng_word = st_pic_cyc[e*32 +: 32];
          REG_RD_CYC[7:0]:    eng_word = st_rd_cyc[e*32 +: 32];
          REG_PK_CYC[7:0]:    eng_word = st_pk_cyc[e*32 +: 32];
          REG_WR_CYC[7:0]:    eng_word = st_wr_cyc[e*32 +: 32];
          default:            eng_word = '0;
        endcase
      end
    end
  end

  // Registered read mux: data the clock after reg_rd_en.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en && (reg_rd_addr[11:8] != 4'd0)) begin
      reg_rd_data <= eng_hit ? eng_word : '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        REG_ID:          reg_rd_data <= CORE_ID;
        REG_VERSION:     reg_rd_data <= CORE_VERSION;
        REG_CAPS:        reg_rd_data <= CORE_CAPS;
        REG_CTRL:        reg_rd_data <= {23'd0, irq_en, 8'd0};
        REG_STATUS:      reg_rd_data <= status_word;
        REG_ERR_CODE:    reg_rd_data <= {24'd0, err_code};
        REG_MB_W:        reg_rd_data <= {24'd0, cfg_mb_w};
        REG_MB_H:        reg_rd_data <= {24'd0, cfg_mb_h};
        REG_SLICES:      reg_rd_data <= {24'd0, cfg_slices};
        REG_QP:          reg_rd_data <= {26'd0, cfg_qp};
        REG_MB_MODE:     reg_rd_data <= {31'd0, cfg_mb_pcm};
        REG_FRAME_NUM:   reg_rd_data <= {16'd0, cfg_frame_num};
        REG_IDR_PIC_ID:  reg_rd_data <= {16'd0, cfg_idr_pic_id};
        REG_PIC_CFG:     reg_rd_data <= {19'd0, cfg_log2_fn, 7'd0, cfg_idr};
        REG_IN_BASE:     reg_rd_data <= cfg_in_base;
        REG_IN_STRIDE:   reg_rd_data <= cfg_in_stride;
        REG_RY_BASE:     reg_rd_data <= cfg_ry_base;
        REG_RU_BASE:     reg_rd_data <= cfg_ru_base;
        REG_RING_BASE:   reg_rd_data <= cfg_ring_base;
        REG_RING_SIZE:   reg_rd_data <= cfg_ring_size;
        REG_RING_WPTR:   reg_rd_data <= ring_wptr[31:0];
        REG_RING_RPTR:   reg_rd_data <= rptr_shadow[0];
        REG_RING_FILL:   reg_rd_data <= ring_fill[31:0];
        REG_IDX_BASE:    reg_rd_data <= cfg_idx_base;
        REG_IDX_ENTRIES: reg_rd_data <= cfg_idx_entries;
        REG_IDX_WPTR:    reg_rd_data <= idx_wptr[31:0];
        REG_IDX_RPTR:    reg_rd_data <= idx_rptr_shadow[0];
        REG_IDX_FILL:    reg_rd_data <= idx_fill[31:0];
        REG_PIC_COUNT:   reg_rd_data <= pic_count;
        REG_SLICE_COUNT: reg_rd_data <= slice_count;
        REG_MB_COUNT:    reg_rd_data <= st_mb_count[31:0];
        REG_CYC_LAST:    reg_rd_data <= st_cyc_last[31:0];
        REG_CYC_MAX:     reg_rd_data <= st_cyc_max[31:0];
        REG_PIC_CYC:     reg_rd_data <= st_pic_cyc[31:0];
        REG_RD_CYC:      reg_rd_data <= st_rd_cyc[31:0];
        REG_PK_CYC:      reg_rd_data <= st_pk_cyc[31:0];
        REG_WR_CYC:      reg_rd_data <= st_wr_cyc[31:0];
        default:         reg_rd_data <= '0;
      endcase
    end
  end

endmodule
