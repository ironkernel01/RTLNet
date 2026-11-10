// -----------------------------------------------------------------------------
// File: rtlnet_h264_recon_wr.sv
// Purpose: write one macroblock of the rebuilt 4:2:0 picture as two burst writes (a 16-beat luma tile and an 8-beat
//   chroma tile) through the write DMA path, from the rebuilt-macroblock RAM that rtlnet_h264_mb_enc fills.
// Overview:
//   * Tile layout of the rebuilt (reference) picture: macroblock m (raster index in the picture) owns 256 bytes of luma at
//     luma_base + 256 * m (16 rows of 16 samples, row 0 first: 16 beats of 128 bits) and 128 bytes of chroma at
//     chroma_base + 128 * m (Cb 8 x 8 rows then Cr 8 x 8 rows: 8 beats, beat k = rows 2k and 2k + 1 of the plane). Both
//     tiles are power-of-two sized and aligned, so no burst crosses 4 KiB.
//   * The rebuilt RAM holds 32-bit words (4 samples) in exactly that order: luma words 0..63, Cb words 64..79, Cr words
//     80..95 of the bank. The 96 words are read in order, four words make one 128-bit beat, and the 24 beats go into a
//     staging RAM (rtlnet_ram_core, 32 x 128 bits). The luma tile (beats 0..15) then streams out as one burst, then the
//     chroma tile (beats 16..23) as another, each beat at one per clock while the write master takes it.
//   * Per tile: a descriptor (rc_valid, rc_addr, rc_len = beats - 1) is held until the master pops it (rc_pop); the
//     beats are offered on rc_w_valid / rc_w_data and the master takes them with rc_w_pop. The first beat is read ahead
//     while the descriptor waits.
//   * start pulses one clock when idle; done pulses after the last beat of the chroma tile is taken.
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-09-2026: initial version for I_PCM; reads the 32-bit rebuilt RAM of phase 2b-2.
//   * 11-10-2026: tile layout and two burst writes (burst-only DDR3 access); staging RAM.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_recon_wr #(
  parameter int    ADDR_W    = 32,
  parameter int    RAM_AW    = 8,
  parameter string RAM_STYLE = "block"
)(
  // Clock and synchronous active-low reset.
  input  logic              clk,
  input  logic              resetn,

  // Macroblock command, clk domain: base is the rebuilt-RAM word address of the bank, y_addr and c_addr the byte addresses
  // of the macroblock's luma tile (multiple of 256) and chroma tile (multiple of 128).
  input  logic              start,
  input  logic [RAM_AW-1:0] base,
  input  logic [ADDR_W-1:0] y_addr,
  input  logic [ADDR_W-1:0] c_addr,
  output logic              busy,
  output logic              done,

  // Rebuilt RAM read port, clk domain: ram_rd_data is valid the clock after ram_rd_en.
  output logic              ram_rd_en,
  output logic [RAM_AW-1:0] ram_rd_addr,
  input  logic [31:0]       ram_rd_data,

  // Tile burst request to the write master, clk domain: descriptor valid with address and beats-1, stable until rc_pop;
  // then the beats on rc_w_*.
  output logic              rc_valid,
  output logic [ADDR_W-1:0] rc_addr,
  output logic [3:0]        rc_len,
  input  logic              rc_pop,
  output logic              rc_w_valid,
  output logic [127:0]      rc_w_data,
  input  logic              rc_w_pop
);

  localparam logic [2:0] S_IDLE = 3'd0;
  localparam logic [2:0] S_RD   = 3'd1;
  localparam logic [2:0] S_GW   = 3'd2;
  localparam logic [2:0] S_L    = 3'd3;
  localparam logic [2:0] S_C    = 3'd4;

  localparam int WORDS     = 96;
  localparam int LUMA_BEATS = 16;
  localparam int CHR_BEATS  = 8;
  localparam int STG_AW     = 5;

  logic [2:0]        st;
  logic [RAM_AW-1:0] base_q;
  logic [6:0]        k;
  logic              cap_v;
  logic [6:0]        cap_k;
  logic [95:0]       acc;
  logic [ADDR_W-1:0] ya_q;
  logic [ADDR_W-1:0] ca_q;
  logic              stg_we;
  logic [STG_AW-1:0] stg_waddr;
  logic [127:0]      stg_wdata;
  logic              stg_rd_en;
  logic [STG_AW-1:0] stg_raddr;
  logic [127:0]      stg_rdata;
  logic [5:0]        issued;
  logic [4:0]        popped;
  logic              v;
  logic              req_pend;
  logic [4:0]        n_beats;
  logic [5:0]        e_end;
  logic              more;
  logic              last_pop;

  assign busy        = (st != S_IDLE);
  assign ram_rd_en   = (st == S_RD);
  assign ram_rd_addr = base_q + RAM_AW'(k);

  assign stg_we    = cap_v && (cap_k[1:0] == 2'd3);
  assign stg_waddr = cap_k[6:2];
  assign stg_wdata = {ram_rd_data, acc};

  assign n_beats  = (st == S_C) ? 5'(CHR_BEATS) : 5'(LUMA_BEATS);
  // Staging entries 0..15 are the luma tile, 16..23 the chroma tile; issued counts the entries read so far.
  assign e_end    = (st == S_C) ? 6'(LUMA_BEATS + CHR_BEATS) : 6'(LUMA_BEATS);
  assign more     = (issued < e_end);
  assign stg_rd_en = ((st == S_L) || (st == S_C)) && more && (!v || rc_w_pop);
  assign stg_raddr = issued[STG_AW-1:0];

  assign rc_valid   = req_pend && ((st == S_L) || (st == S_C));
  assign rc_addr    = (st == S_C) ? ca_q : ya_q;
  assign rc_len     = (st == S_C) ? 4'(CHR_BEATS - 1) : 4'(LUMA_BEATS - 1);
  assign rc_w_valid = v;
  assign rc_w_data  = stg_rdata;
  assign last_pop   = rc_w_pop && (popped == (n_beats - 5'd1));

  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(STG_AW), .READ_LATENCY(1)) u_stage (
    .wr_clk(clk), .wr_en(stg_we), .wr_addr(stg_waddr), .wr_data(stg_wdata),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(stg_rd_en), .rd_addr(stg_raddr), .rd_data(stg_rdata)
  );

  always_ff @(posedge clk) begin
    if (!resetn) begin
      st       <= S_IDLE;
      base_q   <= '0;
      k        <= '0;
      cap_v    <= 1'b0;
      cap_k    <= '0;
      acc      <= '0;
      ya_q     <= '0;
      ca_q     <= '0;
      issued   <= '0;
      popped   <= '0;
      v        <= 1'b0;
      req_pend <= 1'b0;
      done     <= 1'b0;
    end else begin
      done  <= 1'b0;
      cap_v <= (st == S_RD);
      cap_k <= k;
      if (cap_v && (cap_k[1:0] != 2'd3)) acc[32*cap_k[1:0] +: 32] <= ram_rd_data;
      case (st)
        S_IDLE: begin
          if (start) begin
            base_q <= base;
            k      <= '0;
            ya_q   <= y_addr;
            ca_q   <= c_addr;
            st     <= S_RD;
          end
        end
        S_RD: begin
          if (k == 7'(WORDS - 1)) begin
            k  <= '0;
            st <= S_GW;
          end else begin
            k <= k + 7'd1;
          end
        end
        S_GW: begin
          // The last word is captured and written to the staging RAM in this clock.
          st       <= S_L;
          issued   <= '0;
          popped   <= '0;
          v        <= 1'b0;
          req_pend <= 1'b1;
        end
        S_L, S_C: begin
          if (rc_pop) req_pend <= 1'b0;
          if (stg_rd_en) issued <= issued + 6'd1;
          if (stg_rd_en)      v <= 1'b1;
          else if (rc_w_pop)  v <= 1'b0;
          if (rc_w_pop) popped <= popped + 5'd1;
          if (last_pop) begin
            popped <= '0;
            if (st == S_L) begin
              st       <= S_C;
              req_pend <= 1'b1;
            end else begin
              st   <= S_IDLE;
              done <= 1'b1;
            end
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
