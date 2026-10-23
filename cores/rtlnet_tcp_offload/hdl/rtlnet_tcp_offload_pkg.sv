// -----------------------------------------------------------------------------
// File: rtlnet_tcp_offload_pkg.sv
// Purpose: constants shared by the rtlnet_tcp_offload modules: the register
//   map, the CTRL / STATUS / CAPS bit layouts, the pipeline latencies and the
//   receive trailer layout.
// Overview:
//   * Register offsets and bit positions are defined once, in
//     cores/rtlnet_tcp_offload/driver/rtlnet_tcp_offload.h; every localparam
//     of the register-map section below mirrors that header and the two
//     change together in one commit.
//   * ANALYZE_LAT is the number of enabled clocks from the clock in which the
//     final beat of a frame is offered to rtlnet_tcp_offload_analyze to the
//     clock in which its result record is on the outputs. The receive delay
//     line and the transmit consumer are derived from it; the analyzer checks
//     it in simulation.
// Language: SystemVerilog-2012 (synthesizable package).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: none (package).
// -----------------------------------------------------------------------------
package rtlnet_tcp_offload_pkg;

  // Identification (mirrors RTLNET_TXO_ID_VALUE / RTLNET_TXO_VERSION_VALUE).
  localparam logic [31:0] TXO_ID_VALUE      = 32'h5443_504F;   // "TCPO"
  localparam logic [31:0] TXO_VERSION_VALUE = 32'h1022_2026;

  // Register offsets (byte addresses in the 4 KiB window).
  localparam logic [11:0] REG_ID         = 12'h000;
  localparam logic [11:0] REG_VERSION    = 12'h004;
  localparam logic [11:0] REG_CAPS       = 12'h008;
  localparam logic [11:0] REG_CTRL       = 12'h00C;
  localparam logic [11:0] REG_STATUS     = 12'h010;
  localparam logic [11:0] REG_LATENCY    = 12'h014;
  localparam logic [11:0] REG_CNT_CLEAR  = 12'h018;
  localparam logic [11:0] REG_CNT_TX     = 12'h040;   // + 4 i, i = 0..5
  localparam logic [11:0] REG_CNT_RX     = 12'h060;   // + 4 i, i = 0..4

  // Counter indices (offset = REG_CNT_TX / REG_CNT_RX + 4 index).
  localparam int CNT_TX_FRAMES     = 0;
  localparam int CNT_TX_IP_PATCHED = 1;
  localparam int CNT_TX_L4_PATCHED = 2;
  localparam int CNT_TX_SKIPPED    = 3;
  localparam int CNT_TX_MALFORMED  = 4;
  localparam int CNT_TX_DROPPED    = 5;
  localparam int NUM_TX_COUNTERS   = 6;
  localparam int CNT_RX_FRAMES     = 0;
  localparam int CNT_RX_VERIFIED   = 1;
  localparam int CNT_RX_IP_BAD     = 2;
  localparam int CNT_RX_L4_BAD     = 3;
  localparam int CNT_RX_UNVERIFIED = 4;
  localparam int NUM_RX_COUNTERS   = 5;

  // CTRL bits (read back exactly as written; undefined bits read 0).
  localparam int CTRL_TX_IP_CSUM = 0;
  localparam int CTRL_TX_L4_CSUM = 1;
  localparam int CTRL_RX_CSUM    = 2;

  // STATUS bits.
  localparam int STATUS_TX_IDLE  = 0;
  localparam int STATUS_RX_IDLE  = 1;

  // CAPS bits and fields.
  localparam int CAPS_TX_PRESENT   = 0;
  localparam int CAPS_RX_PRESENT   = 1;
  localparam int CAPS_INS_IP       = 2;
  localparam int CAPS_INS_TCP      = 3;
  localparam int CAPS_INS_UDP      = 4;
  localparam int CAPS_VLAN         = 5;
  localparam int CAPS_TX_BUF_LSB   = 8;     // [15:8] TX_BUF_KB
  localparam int CAPS_MAX_FRM_LSB  = 16;    // [26:16] largest frame in bytes

  // Receive trailer (64-bit little-endian word, bit positions).
  localparam logic [7:0] TRAILER_MARKER = 8'hA5;   // upper nibble A: trailer, lower nibble 5: layout version
  localparam int TRL_LEN_LSB    = 0;    // [15:0]  frame length in bytes
  localparam int TRL_SUM_LSB    = 16;   // [31:16] folded ones'-complement L4 sum
  localparam int TRL_FLAGS_LSB  = 32;   // [47:32] flags
  localparam int TRL_L4OFF_LSB  = 48;   // [55:48] L4 offset from the frame start
  localparam int TRL_MARKER_LSB = 56;   // [63:56] marker
  localparam int TRLF_IS_IPV4   = 0;
  localparam int TRLF_IS_TCP    = 1;
  localparam int TRLF_IS_UDP    = 2;
  localparam int TRLF_VLAN      = 3;
  localparam int TRLF_FRAGMENT  = 4;
  localparam int TRLF_IP_OK     = 5;
  localparam int TRLF_L4_OK     = 6;
  localparam int TRLF_VERIFIED  = 7;

  // Pipeline latency of rtlnet_tcp_offload_analyze (enabled clocks, final
  // beat offered -> result record on the outputs).
  localparam int ANALYZE_LAT = 16;
  // Transmit: final beat accepted by the buffer -> sideband entry written (one input register stage
  // in front of the engine, one consumer stage behind it).
  localparam int TX_SB_LAT   = ANALYZE_LAT + 2;
  // Receive: result record -> trailer register (one trailer stage); the data
  // delay line has this many slots.
  localparam int RX_DELAY    = ANALYZE_LAT + 1;

endpackage
