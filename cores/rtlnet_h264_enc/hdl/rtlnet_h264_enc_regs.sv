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
//   * High profile seam (parameter HIGH_PROFILE, default 0): CAPS bit 20 (HP_SEAM) reports the parameter. With HIGH_PROFILE = 1 the
//     register HP_CTRL (0x0C0) holds hp_enable (bit 0, writable only while hp_caps is not 0) and hp_t8_enable (bit 1, the 8x8 transform of inter
//     macroblocks, writable only while hp_caps bit 1 is set) and HP_STATUS (0x0C4) reads present
//     [0], licensed [1], active [2], enable [3], PROFILE_CHG [4] (sticky, set when a picture start applied a changed license or enable
//     and forced an IDR picture, write 1 to clear), caps [11:8] (bit 0 CABAC, bit 1 8x8 transform, bit 2 adaptive transform choice), seconds left [31:16]
//     (0xFFFF unlimited); bit 5 reads the 8x8 transform enable bit and bit 6 the adaptive choice bit (HP_CTRL bit 2, writable only while hp_caps bit 2 is set: with the 8x8 transform enabled, the
//     module chooses the 4x4 or the 8x8 transform per macroblock; clear: the 8x8 transform on every inter macroblock). HP_T8_COUNT (0x0C8, read only):
//     [15:0] macroblocks of the last picture coded with the 8x8 transform, [31:16] with the 4x4 transform (inter macroblocks with luma residual;
//     all engines added). With HIGH_PROFILE = 0 both registers read 0 and the logic is that of the Constrained Baseline encoder.
// Language: SystemVerilog-2012.
// Revision: 11-11-2026
//   * 11-11-2026: High profile seam: CAPS bit 20, HP_CTRL, HP_STATUS.
//   * 11-12-2026: HP_CTRL bit 1 and HP_STATUS bit 5 (8x8 transform enable).
//   * 11-12-2026: HP_CTRL bit 2 and HP_STATUS bit 6 (adaptive transform choice), HP_T8_COUNT.
//   * 11-09-2026: initial version.
//   * 11-10-2026: tiled rebuilt picture: RY_BASE and RU_BASE are the luma and chroma tile bases, the stride registers and
//     RV_BASE are reserved; index records are 128 bytes.
//   * 11-10-2026: phase 2c-1 (P pictures): PIC_CFG bit 1 selects a P picture, REF_Y_BASE (0x054) and REF_U_BASE (0x058) hold the
//     tile bases of the reference picture, VERSION 0x11102C01.
//   * 11-10-2026: phase 2c-2 (motion search): VERSION 0x11102C02, no register change.
// Clocks: clk (all logic).
// -----------------------------------------------------------------------------
module rtlnet_h264_enc_regs #(
  parameter int MAX_MB_W     = 120,
  parameter int MAX_MB_H     = 68,
  parameter int NUM_ENGINES  = 1,
  parameter bit HIGH_PROFILE = 1'b0
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
  output logic        cfg_p,
  output logic [31:0] cfg_refy_base,
  output logic [31:0] cfg_refu_base,
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

  // High profile control and status, clk domain (all 0 / unused when HIGH_PROFILE = 0): hp_enable to the engines; the status of
  // the rtlnet_h264_hp modules (present, licensed, active, caps, seconds left) and hp_chg, a one-clock pulse when a picture start
  // applied a changed license or enable (sets PROFILE_CHG).
  output logic        hp_enable,
  output logic        hp_t8_enable,
  output logic        hp_t8_auto,
  input  logic [15:0] hp_t8_n8,
  input  logic [15:0] hp_t8_n4,
  input  logic        hp_present,
  input  logic        hp_licensed,
  input  logic        hp_active,
  input  logic [3:0]  hp_caps,
  input  logic [15:0] hp_seconds_left,
  input  logic        hp_chg,

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
  // 0x04C (the former luma stride) is reserved: it reads 0 and ignores writes. 0x054 and 0x058 were reserved and are the
  // reference tile bases since phase 2c-1.
  localparam logic [11:0] REG_RU_BASE     = 12'h050;   // rebuilt picture chroma tile base (Cb then Cr, 128 B per macroblock)
  localparam logic [11:0] REG_REFY_BASE   = 12'h054;   // reference picture luma tile base (P pictures; the previous rebuilt picture)
  localparam logic [11:0] REG_REFU_BASE   = 12'h058;   // reference picture chroma tile base (P pictures)
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
  localparam logic [11:0] REG_HP_CTRL     = 12'h0C0;   // [0] hp_enable, [1] hp_t8_enable (High profile seam builds)
  localparam logic [11:0] REG_HP_STATUS   = 12'h0C4;   // see the header
  localparam logic [11:0] REG_HP_T8CNT    = 12'h0C8;   // [15:0] macroblocks of the last picture with the 8x8 transform, [31:16] with the 4x4 transform

  localparam int CTRL_START_BIT      = 0;
  localparam int CTRL_RING_RESET_BIT = 1;
  localparam int CTRL_IRQ_EN_BIT     = 8;
  localparam int STATUS_BUSY_BIT     = 0;
  localparam int STATUS_DONE_BIT     = 1;
  localparam int STATUS_ERR_BIT      = 2;
  localparam int STATUS_STALL_BIT    = 3;
  localparam int HP_STATUS_PRESENT_BIT  = 0;
  localparam int HP_STATUS_LICENSED_BIT = 1;
  localparam int HP_STATUS_ACTIVE_BIT   = 2;
  localparam int HP_STATUS_ENABLE_BIT   = 3;
  localparam int HP_STATUS_CHG_BIT      = 4;
  localparam int HP_STATUS_T8_BIT       = 5;
  localparam int HP_STATUS_AUTO_BIT     = 6;

  localparam logic [31:0] CORE_ID      = id4("H", "2", "6", "4");
  localparam logic [31:0] CORE_VERSION = 32'h1110_2C02;   // 11-10, phase 2c-2 (motion search; the register map is that of 2c-1)
  // CAPS: [7:0] MAX_MB_W, [15:8] MAX_MB_H, [19:16] NUM_ENGINES, [20] HP_SEAM (HIGH_PROFILE build).
  localparam logic [31:0] CORE_CAPS    = {11'd0, HIGH_PROFILE, 4'(NUM_ENGINES), 8'(MAX_MB_H), 8'(MAX_MB_W)};

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
  logic [31:0] hp_status_word;

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

  // High profile registers: present only in a HIGH_PROFILE build; otherwise hp_enable is 0 and HP_STATUS reads 0.
  generate
    if (HIGH_PROFILE) begin : g_hp
      logic chg_flag;

      always_comb begin
        hp_status_word                          = '0;
        hp_status_word[HP_STATUS_PRESENT_BIT]   = hp_present;
        hp_status_word[HP_STATUS_LICENSED_BIT]  = hp_licensed;
        hp_status_word[HP_STATUS_ACTIVE_BIT]    = hp_active;
        hp_status_word[HP_STATUS_ENABLE_BIT]    = hp_enable;
        hp_status_word[HP_STATUS_CHG_BIT]       = chg_flag;
        hp_status_word[HP_STATUS_T8_BIT]        = hp_t8_enable;
        hp_status_word[HP_STATUS_AUTO_BIT]      = hp_t8_auto;
        hp_status_word[11:8]                    = hp_caps;
        hp_status_word[31:16]                   = hp_seconds_left;
      end

      // hp_enable can be set only while the module offers a tool (hp_caps not 0); PROFILE_CHG is sticky, write 1 to clear.
      always_ff @(posedge clk) begin
        if (!resetn) begin
          hp_enable    <= 1'b0;
          hp_t8_enable <= 1'b0;
          hp_t8_auto   <= 1'b0;
          chg_flag     <= 1'b0;
        end else begin
          if (hp_chg) chg_flag <= 1'b1;
          if (reg_wr_en && (reg_wr_addr == REG_HP_CTRL)) begin
            hp_enable    <= reg_wr_data[0] && (|hp_caps);
            hp_t8_enable <= reg_wr_data[1] && hp_caps[1];
            hp_t8_auto   <= reg_wr_data[2] && reg_wr_data[1] && hp_caps[1] && hp_caps[2];
          end
          if (reg_wr_en && (reg_wr_addr == REG_HP_STATUS) && reg_wr_data[HP_STATUS_CHG_BIT] && !hp_chg) chg_flag <= 1'b0;
        end
      end
    end else begin : g_nohp
      assign hp_status_word = '0;
      assign hp_enable      = 1'b0;
      assign hp_t8_enable   = 1'b0;
      assign hp_t8_auto     = 1'b0;

      /* verilator lint_off UNUSEDSIGNAL */
      logic unused_hp;
      assign unused_hp = &{1'b0, hp_present, hp_licensed, hp_active, hp_caps, hp_seconds_left, hp_chg, hp_t8_n8, hp_t8_n4};
      /* verilator lint_on UNUSEDSIGNAL */
    end
  endgenerate

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
      cfg_p           <= 1'b0;
      cfg_log2_fn     <= 5'd4;
      cfg_in_base     <= '0;
      cfg_in_stride   <= '0;
      cfg_ry_base     <= '0;
      cfg_ru_base     <= '0;
      cfg_refy_base   <= '0;
      cfg_refu_base   <= '0;
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
            cfg_p       <= reg_wr_data[1];
            cfg_log2_fn <= reg_wr_data[12:8];
          end
          REG_IN_BASE:     cfg_in_base     <= reg_wr_data;
          REG_IN_STRIDE:   cfg_in_stride   <= reg_wr_data;
          REG_RY_BASE:     cfg_ry_base     <= reg_wr_data;
          REG_RU_BASE:     cfg_ru_base     <= reg_wr_data;
          REG_REFY_BASE:   cfg_refy_base   <= reg_wr_data;
          REG_REFU_BASE:   cfg_refu_base   <= reg_wr_data;
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
        REG_PIC_CFG:     reg_rd_data <= {19'd0, cfg_log2_fn, 6'd0, cfg_p, cfg_idr};
        REG_IN_BASE:     reg_rd_data <= cfg_in_base;
        REG_IN_STRIDE:   reg_rd_data <= cfg_in_stride;
        REG_RY_BASE:     reg_rd_data <= cfg_ry_base;
        REG_RU_BASE:     reg_rd_data <= cfg_ru_base;
        REG_REFY_BASE:   reg_rd_data <= cfg_refy_base;
        REG_REFU_BASE:   reg_rd_data <= cfg_refu_base;
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
        REG_HP_CTRL:     reg_rd_data <= {29'd0, hp_t8_auto, hp_t8_enable, hp_enable};
        REG_HP_T8CNT:    reg_rd_data <= HIGH_PROFILE ? {hp_t8_n4, hp_t8_n8} : 32'd0;
        REG_HP_STATUS:   reg_rd_data <= hp_status_word;
        default:         reg_rd_data <= '0;
      endcase
    end
  end

endmodule
