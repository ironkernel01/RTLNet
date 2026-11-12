// -----------------------------------------------------------------------------
// File: rtlnet_h264_bitpack.sv
// Purpose: bit packer of the H.264 encoder: exp-Golomb and fixed-field writers, Annex B start codes,
//   rbsp trailing bits and emulation prevention, producing a NAL byte stream one byte per clock. With the parameter ALIGN_ONES the
//   command PK_ALIGN1 pads with one bits to a byte boundary (the cabac_alignment_one_bit of the High profile slice data).
// Overview:
//   * Command stage: one command per clock (cmd_valid/cmd_ready). FIELD appends cmd_len (1..32)
//     bits of cmd_val; UE appends ue(v) of cmd_val (0..65534); SE appends se(v) of the signed
//     cmd_val (|cmd_val| < 32768); ALIGN pads with zero bits to a byte boundary; START emits
//     00 00 00 01 (Annex B byte stream format, clause B.1.1) and starts a NAL unit of kind cmd_kind;
//     END appends rbsp_trailing_bits (stop one bit, zero bits to alignment; clause 7.3.2.11) and marks
//     the last byte of the NAL unit.
//   * Accumulator stage: a 64-bit MSB-first accumulator drained one byte per clock; a command waits
//     while it does not fit (overflow is gated in logic) and START waits until the previous NAL
//     unit's bytes have left the accumulator.
//   * Emulation prevention (clause 7.4.1): after two zero bytes inside a NAL unit, a byte of value 0..3
//     is preceded by 0x03. The four start-code bytes bypass it. o_first marks the first start-code
//     byte and o_last the last byte of the NAL unit (the byte holding the stop bit).
//   * Output byte stream o_*: valid/ready, registered.
//   * A simulation check reports a UE/SE value out of range, a bad FIELD length and an accumulator
//     overflow attempt.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk (all logic).
// -----------------------------------------------------------------------------
module rtlnet_h264_bitpack #(
  parameter bit ALIGN_ONES = 1'b0    // 1: command PK_ALIGN1 pads with one bits to a byte boundary (High profile CABAC); 0: not decoded
)(
  // Clock and synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Command input, clk domain: accepted in a clock with cmd_valid and cmd_ready high.
  // cmd_op is a PK_* code; cmd_val and cmd_len as described above; cmd_kind is the NAL
  // kind (NAL_AUD / NAL_SLICE) and is read for START only.
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [2:0]  cmd_op,
  input  logic [31:0] cmd_val,
  input  logic [5:0]  cmd_len,
  input  logic        cmd_kind,

  // NAL byte stream out, clk domain: a byte moves in a clock with o_valid and o_ready high.
  // o_first marks the first byte of a NAL unit (start code), o_last its last byte, o_kind its kind.
  output logic        o_valid,
  input  logic        o_ready,
  output logic [7:0]  o_data,
  output logic        o_first,
  output logic        o_last,
  output logic        o_kind,

  // Status: high when no command or byte is held anywhere in the packer.
  output logic        idle
);

  import rtlnet_h264_pkg::*;

  localparam int ACC_W = 64;

  // Stage R: the registered raw command, as it arrives.
  logic        r_valid;
  logic [2:0]  r_op;
  logic [31:0] r_val;
  logic [5:0]  r_len;
  logic        r_kind;
  logic        r_take;

  // Stage A: the converted command, converted to the code number plus one (UE/SE) or the masked field (FIELD).
  logic        a_valid;
  logic [2:0]  a_op;
  logic [31:0] a_val;
  logic [5:0]  a_len;
  logic        a_kind;
  logic        a_take;

  // Stage L: the field length (exp-Golomb length from the leading-zero count, 1 for the stop bit of END).
  logic        l_valid;
  logic [2:0]  l_op;
  logic [31:0] l_val;
  logic [5:0]  l_len;
  logic        l_kind;
  logic        l_take;

  // Stage 0: the registered command.
  logic        c_valid;
  logic [2:0]  c_op;
  logic [63:0] c_valsh;
  logic [5:0]  c_len;
  logic        c_kind;

  // Stage 1: accumulator and the start-code sequencer.
  logic [ACC_W-1:0] acc;
  logic [6:0]       cnt;
  logic             end_pending;
  logic [1:0]       sc;
  logic             nal_kind;

  // Byte register between the accumulator and the emulation-prevention stage.
  logic             ob_valid;
  logic [7:0]       ob_data;
  logic             ob_raw;
  logic             ob_first;
  logic             ob_last;
  logic             ob_kind;

  // Skid register behind ob_*: holds a byte pushed while ob_* was stalled; ob_free is its (registered) empty flag, so the
  // accumulator never sees the output side's ready.
  logic             ok_valid;
  logic [7:0]       ok_data;
  logic             ok_raw;
  logic             ok_first;
  logic             ok_last;
  logic             ok_kind;
  logic             ob_push;
  logic [7:0]       nb_data;
  logic             nb_raw;
  logic             nb_first;
  logic             nb_last;
  logic             nb_kind;

  // Emulation-prevention state: consecutive zero bytes written (0..2).
  logic [1:0]       z;

  // Stage-0 command conversion.
  logic [31:0]      se_code;
  logic [30:0]      neg_k;
  logic [31:0]      ue_m;
  logic [4:0]       ue_lz;
  logic [31:0]      n_val;
  logic [5:0]       n_len;

  // Stage-1 control.
  logic             s1_take;
  logic             drain;
  logic             start_push;
  logic             ob_take;
  logic             ob_free;
  logic             o_free;
  logic             ep_ins;
  logic [6:0]       cnt_d;
  logic [ACC_W-1:0] acc_d;
  logic [ACC_W-1:0] acc_n;
  logic [6:0]       cnt_n;
  logic [ACC_W-1:0] fld_bits;
  logic             fits;
  logic [3:0]       pad_n;     // padding bits of PK_ALIGN1 (0..7)

  function automatic logic [4:0] floor_log2(input logic [15:0] v);
    logic [4:0] r;
    r = 5'd0;
    for (int i = 0; i < 16; i++) begin
      if (v[i]) r = 5'(i);
    end
    return r;
  endfunction

  // ---------------------------------------------------------------------------
  // Stage 0: convert the command to a (value, length) field
  // ---------------------------------------------------------------------------
  assign neg_k = ~r_val[30:0] + 31'd1;

  always_comb begin
    // se(v) code number plus one (Table 9-3): k > 0 gives 2k, k <= 0 gives 2 * |k| + 1; ue(v) gives v + 1.
    se_code = {neg_k, 1'b1};
    if (!r_val[31]) begin
      se_code = (r_val == 32'd0) ? 32'd1 : {r_val[30:0], 1'b0};
    end
    ue_m  = (r_op == PK_SE) ? se_code : (r_val + 32'd1);
    n_val = '0;
    n_len = '0;
    case (r_op)
      PK_FIELD: begin
        n_val = r_val & (32'hFFFFFFFF >> (6'd32 - r_len));
        n_len = r_len;
      end
      PK_UE, PK_SE: begin
        n_val = ue_m;
        n_len = 6'd0;
      end
      default: begin
        n_val = '0;
        n_len = '0;
      end
    endcase
    // Stage 0 conversion: the exp-Golomb field length 2 * floor(log2(m)) + 1 of a UE/SE entry.
    ue_lz = floor_log2(a_val[15:0]);
  end

  assign l_take    = l_valid && (!c_valid || s1_take);
  assign a_take    = a_valid && (!l_valid || l_take);
  assign r_take    = r_valid && (!a_valid || a_take);
  assign cmd_ready = !r_valid || r_take;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      r_valid <= 1'b0;
      r_op    <= '0;
      r_val   <= '0;
      r_len   <= '0;
      r_kind  <= 1'b0;
    end else if (cmd_ready) begin
      r_valid <= cmd_valid;
      r_op    <= cmd_op;
      r_val   <= cmd_val;
      r_len   <= cmd_len;
      r_kind  <= cmd_kind;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      a_valid <= 1'b0;
      a_op    <= '0;
      a_val   <= '0;
      a_len   <= '0;
      a_kind  <= 1'b0;
    end else if (!a_valid || a_take) begin
      a_valid <= r_valid;
      a_op    <= r_op;
      a_val   <= n_val;
      a_len   <= n_len;
      a_kind  <= r_kind;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      l_valid <= 1'b0;
      l_op    <= '0;
      l_val   <= '0;
      l_len   <= '0;
      l_kind  <= 1'b0;
    end else if (!l_valid || l_take) begin
      l_valid <= a_valid;
      l_op    <= a_op;
      l_val   <= a_val;
      l_len   <= ((a_op == PK_UE) || (a_op == PK_SE)) ? ({ue_lz, 1'b0} + 6'd1) : ((a_op == PK_END) ? 6'd1 : a_len);
      l_kind  <= a_kind;
    end
  end

  // Stage C: the field placed at the top of a 64-bit word (the accumulator stage only shifts it right by the bit count).
  always_ff @(posedge clk) begin
    if (!resetn) begin
      c_valid <= 1'b0;
      c_op    <= '0;
      c_valsh <= '0;
      c_len   <= '0;
      c_kind  <= 1'b0;
    end else if (!c_valid || s1_take) begin
      c_valid <= l_valid;
      c_op    <= l_op;
      c_valsh <= (l_op == PK_END) ? 64'h8000_0000_0000_0000 : ({32'd0, l_val} << (7'd64 - {1'b0, l_len}));
      c_len   <= l_len;
      c_kind  <= l_kind;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 1: accumulator
  // ---------------------------------------------------------------------------
  assign fits = ({1'b0, cnt} + {2'b0, c_len}) <= 8'(ACC_W);

  always_comb begin
    ob_free    = !ok_valid;
    drain      = (cnt >= 7'd8) && ob_free;
    start_push = c_valid && (c_op == PK_START) && (cnt == 7'd0) && !end_pending && ob_free;
    ob_push    = drain || start_push;
    nb_data    = start_push ? ((sc == 2'd3) ? 8'h01 : 8'h00) : acc[ACC_W-1 -: 8];
    nb_raw     = start_push;
    nb_first   = start_push && (sc == 2'd0);
    nb_last    = drain && end_pending && (cnt == 7'd8);
    nb_kind    = start_push ? c_kind : nal_kind;
    s1_take    = 1'b0;
    if (c_valid) begin
      case (c_op)
        PK_FIELD, PK_UE, PK_SE: s1_take = fits && !end_pending;
        PK_ALIGN:               s1_take = !end_pending;
        PK_START:               s1_take = start_push && (sc == 2'd3);
        PK_END:                 s1_take = !end_pending && (cnt <= 7'd63);
        default:                s1_take = 1'b1;
      endcase
    end
    // With ALIGN_ONES the command PK_ALIGN1 waits like ALIGN (the constant condition leaves the logic of the default build as it was).
    if (ALIGN_ONES && c_valid && (c_op == PK_ALIGN1)) s1_take = !end_pending;
    cnt_d    = drain ? (cnt - 7'd8) : cnt;
    acc_d    = drain ? (acc << 8) : acc;
    fld_bits = drain ? (c_valsh >> (cnt - 7'd8)) : (c_valsh >> cnt);
    acc_n    = acc_d;
    cnt_n    = cnt_d;
    if (s1_take) begin
      case (c_op)
        PK_FIELD, PK_UE, PK_SE: begin
          acc_n = acc_d | fld_bits;
          cnt_n = cnt_d + 7'(c_len);
        end
        PK_ALIGN: begin
          cnt_n = (cnt_d + 7'd7) & 7'h78;
        end
        PK_END: begin
          acc_n = acc_d | fld_bits;
          cnt_n = (cnt_d + 7'd8) & 7'h78;
        end
        default: begin
          acc_n = acc_d;
          cnt_n = cnt_d;
        end
      endcase
    end
    // ALIGN1: ones up to the next byte boundary (only with ALIGN_ONES).
    pad_n = 4'(7'd8 - {4'd0, cnt_d[2:0]}) & 4'd7;
    if (ALIGN_ONES && s1_take && (c_op == PK_ALIGN1)) begin
      acc_n = acc_d | (~(64'hFFFF_FFFF_FFFF_FFFF >> pad_n) >> cnt_d);
      cnt_n = (cnt_d + 7'd7) & 7'h78;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      acc         <= '0;
      cnt         <= '0;
      end_pending <= 1'b0;
      sc          <= '0;
      nal_kind    <= NAL_AUD;
      ob_valid    <= 1'b0;
      ob_data     <= '0;
      ob_raw      <= 1'b0;
      ob_first    <= 1'b0;
      ob_last     <= 1'b0;
      ob_kind     <= NAL_AUD;
      ok_valid    <= 1'b0;
      ok_data     <= '0;
      ok_raw      <= 1'b0;
      ok_first    <= 1'b0;
      ok_last     <= 1'b0;
      ok_kind     <= NAL_AUD;
    end else begin
      acc <= acc_n;
      cnt <= cnt_n;
      if (s1_take && (c_op == PK_END)) begin
        end_pending <= 1'b1;
      end else if (drain && end_pending && (cnt == 7'd8)) begin
        end_pending <= 1'b0;
      end
      if (start_push) begin
        sc <= (sc == 2'd3) ? 2'd0 : (sc + 2'd1);
        if (sc == 2'd0) nal_kind <= c_kind;
      end
      if (ob_take || !ob_valid) begin
        if (ok_valid) begin
          ob_valid <= 1'b1;
          ob_data  <= ok_data;
          ob_raw   <= ok_raw;
          ob_first <= ok_first;
          ob_last  <= ok_last;
          ob_kind  <= ok_kind;
          ok_valid <= 1'b0;
        end else begin
          ob_valid <= ob_push;
          ob_data  <= nb_data;
          ob_raw   <= nb_raw;
          ob_first <= nb_first;
          ob_last  <= nb_last;
          ob_kind  <= nb_kind;
        end
      end else if (ob_push) begin
        ok_valid <= 1'b1;
        ok_data  <= nb_data;
        ok_raw   <= nb_raw;
        ok_first <= nb_first;
        ok_last  <= nb_last;
        ok_kind  <= nb_kind;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Emulation prevention and output register
  // ---------------------------------------------------------------------------
  assign ep_ins  = ob_valid && !ob_raw && (z == 2'd2) && (ob_data <= 8'h03);
  assign o_free  = !o_valid || o_ready;
  assign ob_take = ob_valid && o_free && !ep_ins;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      o_valid <= 1'b0;
      o_data  <= '0;
      o_first <= 1'b0;
      o_last  <= 1'b0;
      o_kind  <= NAL_AUD;
      z       <= '0;
    end else if (o_free) begin
      o_valid <= ob_valid;
      if (ep_ins) begin
        o_data  <= 8'h03;
        o_first <= 1'b0;
        o_last  <= 1'b0;
        o_kind  <= ob_kind;
        z       <= 2'd0;
      end else if (ob_valid) begin
        o_data  <= ob_data;
        o_first <= ob_first;
        o_last  <= ob_last;
        o_kind  <= ob_kind;
        if (ob_raw || (ob_data != 8'h00)) begin
          z <= 2'd0;
        end else if (z != 2'd2) begin
          z <= z + 2'd1;
        end
      end
    end
  end

  assign idle = !r_valid && !a_valid && !l_valid && !c_valid && (cnt == 7'd0) && !ob_valid && !ok_valid && !o_valid && !end_pending && (sc == 2'd0);

  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (resetn && cmd_valid && cmd_ready) begin
      if (((cmd_op == PK_UE) && (cmd_val > 32'd65534)) ||
          ((cmd_op == PK_SE) && (($signed(cmd_val) > 32767) || ($signed(cmd_val) < -32767)))) begin
        $error("rtlnet_h264_bitpack: UE/SE value 0x%0h out of range", cmd_val);
      end
      if ((cmd_op == PK_FIELD) && ((cmd_len == 6'd0) || (cmd_len > 6'd32))) begin
        $error("rtlnet_h264_bitpack: FIELD length %0d", cmd_len);
      end
    end
    if (resetn && (cnt_n > 7'd64)) begin
      $error("rtlnet_h264_bitpack: accumulator overflow, cnt %0d", cnt_n);
    end
  end
  // synthesis translate_on

endmodule
