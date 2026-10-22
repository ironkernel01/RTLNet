// -----------------------------------------------------------------------------
// File: rtlnet_classifier_pkg.sv
// Purpose: constants shared by the rtlnet_classifier modules: the register
//   map, the entry and mode bit layouts, the operator codes and the pipeline
//   stage counts from which VERDICT_LATENCY and DELAY_BEATS are derived.
// Overview:
//   * Register offsets and bit positions are defined once, in
//     cores/rtlnet_classifier/driver/rtlnet_classifier.h; every localparam of
//     the register-map section below mirrors that header and the two change
//     together in one commit. If they drift, a driver write lands in the
//     wrong register (or in none: undefined offsets ignore writes and read 0)
//     and the filter silently runs a configuration nobody wrote.
//   * Field values are in number order: the first wire byte of a field is its
//     most significant byte (MAC 00:11:22:33:44:55 = 48'h001122334455).
//   * Stage counts: each localparam is the number of registers a frame's
//     decision passes through in one block; the top level sums them into
//     VERDICT_LATENCY (no hand-entered latency anywhere).
// Language: SystemVerilog-2012 (synthesizable package).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: none (package).
// -----------------------------------------------------------------------------
package rtlnet_classifier_pkg;

  // ---------------------------------------------------------------------------
  // Identification (mirrors RTLNET_CLS_ID_VALUE / RTLNET_CLS_VERSION_VALUE)
  // ---------------------------------------------------------------------------
  localparam logic [31:0] CLS_ID_VALUE      = 32'h434C_5346;   // "CLSF"
  localparam logic [31:0] CLS_VERSION_VALUE = 32'h1022_2026;

  // ---------------------------------------------------------------------------
  // Register offsets (byte addresses in the 4 KiB window)
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID          = 12'h000;
  localparam logic [11:0] REG_VERSION     = 12'h004;
  localparam logic [11:0] REG_CAPS        = 12'h008;
  localparam logic [11:0] REG_CTRL        = 12'h00C;
  localparam logic [11:0] REG_STATUS      = 12'h010;
  localparam logic [11:0] REG_LATENCY     = 12'h014;
  localparam logic [11:0] REG_TABLE_MODE  = 12'h020;   // + 4 t, t = 0..5
  localparam logic [11:0] REG_RULE_MODE   = 12'h040;   // + 4 r, r = 0..3
  localparam logic [11:0] REG_CNT_BASE    = 12'h080;   // 16 counters, 0x080..0x0BC
  localparam logic [11:0] REG_POLICER     = 12'h100;   // + 0x20 p, p = 0..3
  localparam logic [11:0] REG_ENTRY_BASE  = 12'h400;   // + 0x100 t + 0x10 e
  localparam logic [11:0] REG_TUPLE_BASE  = 12'h900;   // + 0x20 e
  localparam logic [11:0] REG_RULE_BASE   = 12'hC00;   // + RULE_STRIDE r + 4 b
  localparam logic [11:0] REG_MIRROR_BASE = 12'h400;   // first entry-memory offset

  // Counter word index inside the counter block (offset = 0x080 + 4 index).
  localparam int CNT_FRAMES          = 0;
  localparam int CNT_PASSED          = 1;
  localparam int CNT_DROPPED         = 2;
  localparam int CNT_MODE_DROPPED    = 3;
  localparam int CNT_POLICE_DROPPED  = 4;
  localparam int CNT_TABLE_HIT       = 5;    // + t, t = 0..5
  localparam int CNT_RULE_HIT        = 11;   // + r, r = 0..3
  localparam int CNT_OVERRUN_DROPPED = 15;
  localparam int NUM_COUNTERS        = 16;

  // Policer register word index (offset = 0x100 + 0x20 p + 4 index).
  localparam int POL_CTRL    = 0;
  localparam int POL_LIMIT   = 1;
  localparam int POL_WINDOW  = 2;
  localparam int POL_SEEN    = 3;
  localparam int POL_PASSED  = 4;
  localparam int POL_DROPPED = 5;
  localparam int POL_BUDGET  = 6;
  localparam int POL_WORDS   = 8;

  // CTRL bits.
  localparam int CTRL_MODE_LSB     = 0;    // [1:0]
  localparam int CTRL_CLEAR_TABLES = 8;    // self-clearing pulse
  localparam int CTRL_CNT_CLEAR    = 16;   // self-clearing pulse

  // STATUS bits.
  localparam int STATUS_CLEARING   = 0;
  localparam int STATUS_MODE_LSB   = 8;    // [9:8]
  localparam int STATUS_STALL_SEEN = 16;   // sticky, cleared by CNT_CLEAR

  // CAPS fields (LSB positions).
  localparam int CAPS_TABLE_ENTRIES_LSB = 0;    // [4:0]
  localparam int CAPS_TUPLE_ENTRIES_LSB = 5;    // [9:5]
  localparam int CAPS_NUM_RULES_LSB     = 10;   // [12:10]
  localparam int CAPS_NUM_POLICERS_LSB  = 13;   // [15:13]
  localparam int CAPS_TABLE_LANES_LSB   = 16;   // [20:16]
  localparam int CAPS_MATCH_BEATS_LSB   = 21;   // [26:21] MATCH_DEPTH_BYTES / 8

  // LATENCY fields.
  localparam int LAT_DELAY_BEATS_LSB     = 0;   // [7:0]
  localparam int LAT_VERDICT_LATENCY_LSB = 8;   // [15:8]

  // ---------------------------------------------------------------------------
  // Tables, modes, operators
  // ---------------------------------------------------------------------------
  localparam int TBL_MAC          = 0;
  localparam int TBL_ETHERTYPE    = 1;
  localparam int TBL_VLAN         = 2;
  localparam int TBL_IP           = 3;
  localparam int TBL_PORT         = 4;
  localparam int TBL_TUPLE        = 5;
  localparam int NUM_FIELD_TABLES = 5;
  localparam int NUM_TABLES       = 6;

  // Global MODE (CTRL[1:0]).
  localparam logic [1:0] MODE_DROP_ALL      = 2'b00;
  localparam logic [1:0] MODE_PASS_ALL      = 2'b01;
  localparam logic [1:0] MODE_PASS_ON_MATCH = 2'b10;
  localparam logic [1:0] MODE_DROP_ON_MATCH = 2'b11;

  // TABLE_MODE bits.
  localparam int TM_ENABLE      = 0;
  localparam int TM_EXCLUDE     = 1;
  localparam int TM_COMPARE_LSB = 2;      // [3:2]
  localparam int TM_CLASSIFY    = 4;
  localparam int TM_VLAN_AWARE  = 7;

  // TABLE_MODE.COMPARE.
  localparam logic [1:0] CMP_SINGLE = 2'b00;
  localparam logic [1:0] CMP_RANGE  = 2'b01;
  localparam logic [1:0] CMP_MASK   = 2'b10;

  // RULE_MODE bits.
  localparam int RM_ENABLE      = 0;
  localparam int RM_EXCLUDE     = 1;
  localparam int RM_CLASSIFY    = 2;
  localparam int RM_POLICE_EN   = 3;
  localparam int RM_POLICER_LSB = 4;      // [5:4]

  // Field-table entry word +4 (control word) bits.
  localparam int FE_SRC_HI_LSB = 0;       // [15:0] SRC_VALUE[47:32]
  localparam int FE_PROTO_LSB  = 16;      // [23:16]
  localparam int FE_POLICER_LSB = 24;     // [25:24]
  localparam int FE_POLICE_EN  = 26;
  localparam int FE_PROTO_EN   = 27;
  localparam int FE_BOTH       = 28;
  localparam int FE_DST_EN     = 29;
  localparam int FE_SRC_EN     = 30;
  localparam int FE_VALID      = 31;

  // Tuple entry word +0 (control word) bits.
  localparam int TE_PROTO_LSB   = 0;      // [7:0]
  localparam int TE_POLICER_LSB = 8;      // [9:8]
  localparam int TE_POLICE_EN   = 29;
  localparam int TE_PROTO_EN    = 30;
  localparam int TE_VALID       = 31;

  // Tuple entry word index (offset = 0x900 + 0x20 e + 4 index).
  localparam int TW_CTRL     = 0;
  localparam int TW_SRC_IP   = 1;
  localparam int TW_SRC_MASK = 2;
  localparam int TW_DST_IP   = 3;
  localparam int TW_DST_MASK = 4;
  localparam int TW_SPORT    = 5;         // [15:0] LO, [31:16] HI
  localparam int TW_DPORT    = 6;
  localparam int TUPLE_WORDS = 7;

  // Rule compare-buffer word bits.
  localparam int RB_COMPARE_LSB = 0;      // [7:0]
  localparam int RB_OP_LSB      = 8;      // [11:8]
  localparam int RB_MASK_LSB    = 24;     // [31:24]
  localparam int RB_STORE_W     = 20;     // stored {MASK, OP, COMPARE}

  // Rule operators (any other code is don't-care).
  localparam logic [3:0] OP_EQ = 4'b1000;
  localparam logic [3:0] OP_NE = 4'b1001;
  localparam logic [3:0] OP_LT = 4'b1010;
  localparam logic [3:0] OP_GT = 4'b1011;
  localparam logic [3:0] OP_LE = 4'b1100;
  localparam logic [3:0] OP_GE = 4'b1101;

  // Policer selection field width (entries and rules), policers built at most.
  localparam int POLICER_SEL_W = 2;
  localparam int MAX_POLICERS  = 4;
  localparam int MAX_RULES     = 4;

  // ---------------------------------------------------------------------------
  // Pipeline stage counts (registers on the decision path)
  // ---------------------------------------------------------------------------
  // Delay line entry: the beat taken into slot 0 is registered into the
  // engine tap (1), the field capture registers (1) and the per-table
  // snapshot loaded by an accepted judge (1).
  localparam int TAP_STAGES      = 1;
  localparam int CAPTURE_STAGES  = 1;
  localparam int SNAPSHOT_STAGES = 1;
  // Table engine from its first compare cycle: chunk compare, chunk merge,
  // side hit, entry hit, lane reduce, window accumulate, result latch.
  localparam int TABLE_STAGES    = 7;
  // Rule engine from the tap: compare-buffer read (2), mask, compare,
  // operator, beat AND, frame accumulate.
  localparam int RULE_STAGES     = 7;
  // Combiner: contributions, AND/OR tree and priority groups, mode.
  localparam int COMB_STAGES     = 3;
  // Policer decision.
  localparam int POLICE_STAGES   = 1;
  // Verdict queue write before the head shows the verdict.
  localparam int QUEUE_STAGES    = 1;
  // Policer budget feedback: decision, decrement, nonzero flag, blocking
  // flag. Consecutive accepted judges are at least this far apart.
  localparam int POLICE_GAP      = 4;

  // Smallest legal frame at the stream boundary, in beats (60 bytes).
  localparam int MIN_FRAME_BEATS = 8;

  // Decode helpers --------------------------------------------------------------
  // True when op is one of the six compare operators.
  function automatic logic op_is_compare(input logic [3:0] op);
    return (op[3] == 1'b1) && (op[2:0] <= 3'd5);
  endfunction

endpackage
