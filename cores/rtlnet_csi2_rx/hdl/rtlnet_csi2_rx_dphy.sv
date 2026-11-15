// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_dphy.sv
// Purpose: D-PHY receiver front end of the CSI-2 camera receiver: two data lanes and a clock lane in, byte-aligned and deskewed
//   byte pairs out on the byte clock. Handles the HS clock, the LP state sequences, the HS settle time, byte alignment on the sync byte
//   and the lane skew.
// Overview:
//   * rtlnet_csi2_rx_dphy_io (the only vendor-specific part, TARGET) delivers the byte clock and one raw byte per lane. In the
//     ref_clk domain rtlnet_csi2_rx_dphy_ctl tracks the LP signals of the three lanes and detects the HS clock; its hs_go per lane
//     (burst running and settled) crosses into the byte clock through a two-flop synchronizer. rtlnet_csi2_rx_lane (one per data
//     lane) aligns the bytes on the sync byte; rtlnet_csi2_rx_deskew merges the lanes into pairs.
//   * Resets: arstn is the asynchronous assertion source (system reset, soft reset). ref_resetn, byte_resetn_g and byte_resetn are
//     synchronous releases from rtlnet_reset_sync. byte_resetn_g (global) is held only by arstn: FIFO pointers and event crossings
//     use it. byte_resetn (logic) is also held while the HS clock is not running (NONCONT_CLOCK = 0), so that the lane and packet state
//     machines restart with the clock (a clock that stops in the middle of a frame leaves no half-finished packet behind). With
//     NONCONT_CLOCK = 1 (a sensor that stops the clock between bursts) the logic is not reset by a stopped clock: the end of a burst
//     (the output hold of rtlnet_csi2_rx_lane, the end event) is completed with the first clocks of the next burst, which come before
//     its data, because the clock may stop only about ten byte clocks after the lane left the burst.
//   * Configuration inputs are quasi-static levels from the core clock domain: they are synchronized into ref_clk and, for lane_en
//     and bit_rev, into the byte clock. Write them while the receiver is idle.
//   * Status outputs are levels for the caller to synchronize: st_clk_running, st_hs, st_lp_d0, st_lp_d1 (ref_clk), st_locked (byte_clk).
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// Clocks: byte_clk (output, derived from the HS clock: pair stream and lane logic), ref_clk (200 MHz: LP trackers, clock detector,
//   IDELAY load, IDELAYCTRL). Crossings: byte_tog byte->ref (3 flops in dphy_ctl); hs_go ref->byte (2 flops here); cfg_* core->ref and
//   cfg_lane_en, cfg_bit_rev core->byte (levels, 2 flops); st_* to the caller.
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_dphy #(
  parameter string TARGET          = "GENERIC",   // "AMD" selects the 7-series primitives of rtlnet_csi2_rx_dphy_io
  parameter bit    NONCONT_CLOCK   = 1'b0,        // 1: the BUFR divider is held in reset while the clock lane is in the stop state
  parameter bit    IDELAYCTRL_INST = 1'b1,
  parameter bit    HS_DIFF_TERM    = 1'b1,        // see rtlnet_csi2_rx_dphy_io
  parameter int    SYNC_WINDOW     = 24,
  parameter int    MAX_SKEW        = 3,
  parameter int    CLK_STOP_CLKS   = 64
)(
  // Reference clock (200 MHz) and the asynchronous reset source (active low).
  input  logic       ref_clk,
  input  logic       arstn,

  // Pins: HS clock pair, HS data pairs, LP pins {Dp, Dn} of the clock lane and each data lane.
  input  logic       hs_clk_p,
  input  logic       hs_clk_n,
  input  logic [1:0] hs_dat_p,
  input  logic [1:0] hs_dat_n,
  input  logic [1:0] lp_clk,
  input  logic [1:0] lp_d0,
  input  logic [1:0] lp_d1,

  // Configuration (levels from the core clock domain).
  input  logic [4:0] cfg_tap0,
  input  logic [4:0] cfg_tap1,
  input  logic [7:0] cfg_settle,
  input  logic [1:0] cfg_lane_en,
  input  logic       cfg_enable,
  input  logic       cfg_bit_rev,

  // Byte clock, its resets and the pair stream.
  output logic       byte_clk,
  output logic       byte_resetn,
  output logic       byte_resetn_g,
  output logic       p_valid,
  output logic [15:0] p_data,
  output logic       p_first,
  output logic       p_end,
  output logic       ev_sot,

  // Status levels.
  output logic       st_clk_running,
  output logic [1:0] st_hs,
  output logic [1:0] st_locked,
  output logic [1:0] st_lp_d0,
  output logic [1:0] st_lp_d1,
  output logic       st_dlyctl_rdy
);

  logic        ref_resetn;
  logic        run_arstn;
  logic        byte_tog;
  logic [7:0]  raw0, raw1;
  logic        clk_stop;
  logic [1:0]  hs_go_ref;
  logic [1:0]  hs_go_byte;
  logic [4:0]  tap0_r, tap1_r;
  logic [7:0]  settle_r;
  logic [1:0]  lane_en_r;
  logic        enable_r;
  logic [1:0]  lane_en_b;
  logic        bit_rev_b;
  logic [7:0]  l0_data, l1_data;
  logic        l0_valid, l1_valid, l0_first, l1_first, l0_locked, l1_locked, l0_active, l1_active, l0_err, l1_err;
  logic        dlyctl_rdy;

  // Resets.
  rtlnet_reset_sync #(.STAGES(4)) u_ref_rst (.clk(ref_clk), .arstn(arstn), .resetn(ref_resetn));
  rtlnet_reset_sync #(.STAGES(4)) u_bytg_rst (.clk(byte_clk), .arstn(arstn), .resetn(byte_resetn_g));
  assign run_arstn = arstn && (NONCONT_CLOCK || st_clk_running);
  rtlnet_reset_sync #(.STAGES(4)) u_byt_rst (.clk(byte_clk), .arstn(run_arstn), .resetn(byte_resetn));

  // Configuration into ref_clk.
  rtlnet_sync #(.WIDTH(5 + 5 + 8 + 2 + 1), .STAGES(2)) u_cfg_ref (
    .clk(ref_clk), .resetn(ref_resetn),
    .d({cfg_tap0, cfg_tap1, cfg_settle, cfg_lane_en, cfg_enable}),
    .q({tap0_r, tap1_r, settle_r, lane_en_r, enable_r})
  );
  // lane_en and bit_rev into byte_clk.
  rtlnet_sync #(.WIDTH(3), .STAGES(2)) u_cfg_byte (
    .clk(byte_clk), .resetn(byte_resetn_g), .d({cfg_lane_en, cfg_bit_rev}), .q({lane_en_b, bit_rev_b})
  );

  rtlnet_csi2_rx_dphy_io #(.TARGET(TARGET), .IDELAYCTRL_INST(IDELAYCTRL_INST), .HS_DIFF_TERM(HS_DIFF_TERM)) u_io (
    .ref_clk(ref_clk), .ref_resetn(ref_resetn),
    .hs_clk_p(hs_clk_p), .hs_clk_n(hs_clk_n), .hs_dat_p(hs_dat_p), .hs_dat_n(hs_dat_n),
    .tap0(tap0_r), .tap1(tap1_r), .bufr_clr(NONCONT_CLOCK && clk_stop),
    .byte_resetn(byte_resetn),
    .byte_clk(byte_clk), .byte_tog(byte_tog), .raw0(raw0), .raw1(raw1), .dlyctl_rdy(dlyctl_rdy)
  );

  rtlnet_csi2_rx_dphy_ctl #(.CLK_STOP_CLKS(CLK_STOP_CLKS)) u_ctl (
    .ref_clk(ref_clk), .ref_resetn(ref_resetn),
    .lp_clk(lp_clk), .lp_d0(lp_d0), .lp_d1(lp_d1),
    .byte_tog(byte_tog), .cfg_settle(settle_r), .cfg_lane_en(lane_en_r), .cfg_enable(enable_r),
    .hs_go(hs_go_ref), .clk_running(st_clk_running), .clk_stop(clk_stop),
    .lp_state_d0(st_lp_d0), .lp_state_d1(st_lp_d1)
  );

  rtlnet_sync #(.WIDTH(2), .STAGES(2)) u_hs_sync (
    .clk(byte_clk), .resetn(byte_resetn), .d(hs_go_ref), .q(hs_go_byte)
  );

  rtlnet_csi2_rx_lane #(.SYNC_WINDOW(SYNC_WINDOW)) u_lane0 (
    .byte_clk(byte_clk), .byte_resetn(byte_resetn), .raw(raw0), .hs_go(hs_go_byte[0]), .bit_rev(bit_rev_b),
    .o_data(l0_data), .o_valid(l0_valid), .o_first(l0_first), .o_locked(l0_locked), .active(l0_active), .ev_sync_err(l0_err)
  );
  rtlnet_csi2_rx_lane #(.SYNC_WINDOW(SYNC_WINDOW)) u_lane1 (
    .byte_clk(byte_clk), .byte_resetn(byte_resetn), .raw(raw1), .hs_go(hs_go_byte[1]), .bit_rev(bit_rev_b),
    .o_data(l1_data), .o_valid(l1_valid), .o_first(l1_first), .o_locked(l1_locked), .active(l1_active), .ev_sync_err(l1_err)
  );

  rtlnet_csi2_rx_deskew #(.MAX_SKEW(MAX_SKEW)) u_deskew (
    .byte_clk(byte_clk), .byte_resetn(byte_resetn), .lane_en(lane_en_b),
    .l0_data(l0_data), .l0_valid(l0_valid), .l0_first(l0_first), .l0_active(l0_active), .l0_err(l0_err),
    .l1_data(l1_data), .l1_valid(l1_valid), .l1_first(l1_first), .l1_active(l1_active), .l1_err(l1_err),
    .p_valid(p_valid), .p_data(p_data), .p_first(p_first), .p_end(p_end), .ev_sot(ev_sot)
  );

  assign st_hs         = hs_go_ref;
  assign st_locked     = {l1_locked, l0_locked};
  assign st_dlyctl_rdy = dlyctl_rdy;

endmodule
