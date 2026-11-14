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
// Revision: 11-14-2026
//   * 11-14-2026: ACK coalescing and receive batching registers, counters, CAPS bits (features appended;
//     the registers of the first version are unchanged).
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
  localparam logic [11:0] REG_CAPS2      = 12'h01C;   // RO, 0 unless a feature below is built
  localparam logic [11:0] REG_ACK_TIMER  = 12'h020;   // RW, ACK_COALESCE build only
  localparam logic [11:0] REG_ACK_LIMIT  = 12'h024;   // RW, ACK_COALESCE build only
  localparam logic [11:0] REG_BAT_TIMER  = 12'h028;   // RW, RX_BATCH build only
  localparam logic [11:0] REG_BAT_FRAMES = 12'h02C;   // RW, RX_BATCH build only
  localparam logic [11:0] REG_BAT_BYTES  = 12'h030;   // RW, RX_BATCH build only
  localparam logic [11:0] REG_CNT_TX     = 12'h040;   // + 4 i, i = 0..5
  localparam logic [11:0] REG_CNT_RX     = 12'h060;   // + 4 i, i = 0..4
  localparam logic [11:0] REG_CNT_ACK    = 12'h080;   // + 4 i, i = 0..5 (ACK_COALESCE build only)
  localparam logic [11:0] REG_CNT_BAT    = 12'h0A0;   // + 4 i, i = 0..5 (RX_BATCH build only)

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
  localparam int CNT_ACK_CAND      = 0;   // pure-ACK candidates seen
  localparam int CNT_ACK_DROPPED   = 1;   // held ACKs replaced by a newer one and dropped
  localparam int CNT_ACK_FWD       = 2;   // candidate ACKs forwarded
  localparam int CNT_ACK_FL_TIMER  = 3;   // held ACK forwarded: timer
  localparam int CNT_ACK_FL_LIMIT  = 4;   // held ACK forwarded: coalesce count limit
  localparam int CNT_ACK_FL_ORDER  = 5;   // held ACK forwarded: ordering, non-coalescable frame, eviction, disable
  localparam int NUM_ACK_COUNTERS  = 6;
  localparam int CNT_BAT_BATCHES   = 0;   // batches closed
  localparam int CNT_BAT_FRAMES    = 1;   // frames carried in batches
  localparam int CNT_BAT_CL_BYTES  = 2;   // batch closed: byte limit
  localparam int CNT_BAT_CL_COUNT  = 3;   // batch closed: frame-count limit
  localparam int CNT_BAT_CL_TIMER  = 4;   // batch closed: timer
  localparam int CNT_BAT_CL_OTHER  = 5;   // batch closed: feature disabled or a frame without trailer follows
  localparam int NUM_BAT_COUNTERS  = 6;

  // CTRL bits (read back exactly as written; undefined bits read 0).
  localparam int CTRL_TX_IP_CSUM = 0;
  localparam int CTRL_TX_L4_CSUM = 1;
  localparam int CTRL_RX_CSUM    = 2;
  localparam int CTRL_ACK_COAL   = 3;   // reads 0 and ignores writes unless the ACK_COALESCE build
  localparam int CTRL_RX_BATCH   = 4;   // reads 0 and ignores writes unless the RX_BATCH build

  // STATUS bits.
  localparam int STATUS_TX_IDLE  = 0;
  localparam int STATUS_RX_IDLE  = 1;
  localparam int STATUS_ACK_IDLE = 2;   // 0 unless built; no held ACK, no frame in the coalescer
  localparam int STATUS_BAT_IDLE = 3;   // 0 unless built; no batch open

  // CAPS bits and fields.
  localparam int CAPS_TX_PRESENT   = 0;
  localparam int CAPS_RX_PRESENT   = 1;
  localparam int CAPS_INS_IP       = 2;
  localparam int CAPS_INS_TCP      = 3;
  localparam int CAPS_INS_UDP      = 4;
  localparam int CAPS_VLAN         = 5;
  localparam int CAPS_ACK_COAL     = 6;     // ACK_COALESCE built
  localparam int CAPS_RX_BATCH     = 7;     // RX_BATCH built
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

  // Reset values of the feature configuration registers.
  localparam int ACK_TIMER_DEFAULT_US  = 200;
  localparam int ACK_LIMIT_DEFAULT     = 8;
  localparam int BAT_TIMER_DEFAULT_US  = 30;
  localparam int BAT_FRAMES_DEFAULT    = 16;
  localparam int BAT_BYTES_DEFAULT     = 8192;

  // ACK coalescer: a frame is held in a slot of 16 beats; the first ACK_HEAD_BEATS beats of every frame
  // are staged (a coalescing candidate has at most 9 data beats and the trailer).
  localparam int ACK_HEAD_BEATS = 10;

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
