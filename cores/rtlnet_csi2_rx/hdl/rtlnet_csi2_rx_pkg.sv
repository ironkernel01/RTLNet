// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_pkg.sv
// Purpose: constants and pure functions of the CSI-2 receiver: data type codes, the packet header ECC (single-error
//   correct, double-error detect), the payload CRC-16, and the layout of one entry of the byte-clock to core-clock FIFO.
// Overview:
//   * Header ECC: the 24 header bits D0..D23 (data identifier D0..D7, word count low D8..D15, word count high D16..D23, each byte
//     least significant bit first) produce six parity bits P0..P5; the ECC byte is {2'b00, P5..P0}. Each data bit is in three or
//     five parity groups and the 24 columns are distinct, so one flipped bit gives a syndrome that names the bit (or a single
//     parity bit) and two flipped bits give a syndrome that matches nothing or an even-weight one.
//   * hdr_ecc_check takes the received 24 bits and ECC byte and returns the corrected bits and a status: 0 clean, 1 one bit
//     corrected (data or ECC byte), 2 uncorrectable. ECC byte bits 7:6 are expected zero and count as syndrome bits.
//   * crc16_byte: CRC-16 of the x^16 + x^12 + x^5 + 1 polynomial, reflected (0x8408), initial value 0xFFFF, no final inversion, bytes in
//     transmission order; the CRC is sent low byte first. Check value of the nine ASCII digits 1 to 9 is 0x6F91.
//   * FIFO entry (46 bits): {fe, eol, sof, cnt[2:0], pix3, pix2, pix1, pix0}, ten bits per pixel. cnt is the pixel count (4 for a
//     full entry, 0 for a marker). A marker with eol set closes a line that ended without its last pixel; a marker with fe set is the
//     frame end.
// Language: SystemVerilog-2012 (synthesizable package).
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// Clocks: none (package).
// -----------------------------------------------------------------------------
package rtlnet_csi2_rx_pkg;

  // Data types (CSI-2 table of data types).
  localparam logic [5:0] DT_FS    = 6'h00;   // frame start
  localparam logic [5:0] DT_FE    = 6'h01;   // frame end
  localparam logic [5:0] DT_LS    = 6'h02;   // line start
  localparam logic [5:0] DT_LE    = 6'h03;   // line end
  localparam logic [5:0] DT_RAW10 = 6'h2B;

  // FIFO entry layout.
  localparam int ENT_W   = 46;
  localparam int ENT_PIX = 0;     // [39:0]
  localparam int ENT_CNT = 40;    // [42:40]
  localparam int ENT_SOF = 43;
  localparam int ENT_EOL = 44;
  localparam int ENT_FE  = 45;

  // Parity masks over D0..D23.
  localparam logic [23:0] ECC_MASK0 = 24'hF12CB7;
  localparam logic [23:0] ECC_MASK1 = 24'hF2555B;
  localparam logic [23:0] ECC_MASK2 = 24'h749A6D;
  localparam logic [23:0] ECC_MASK3 = 24'hB8E38E;
  localparam logic [23:0] ECC_MASK4 = 24'hDF03F0;
  localparam logic [23:0] ECC_MASK5 = 24'hEFFC00;

  function automatic logic [5:0] hdr_parity(input logic [23:0] d);
    hdr_parity = {^(d & ECC_MASK5), ^(d & ECC_MASK4), ^(d & ECC_MASK3), ^(d & ECC_MASK2), ^(d & ECC_MASK1), ^(d & ECC_MASK0)};
  endfunction

  // Result of the header check: {status[1:0], corrected data[23:0]}.
  function automatic logic [25:0] hdr_ecc_check(input logic [23:0] d, input logic [7:0] ecc);
    logic [7:0]  syn;
    logic [23:0] fixed;
    logic [1:0]  st;
    logic        hit;
    logic [5:0]  col;
    syn   = {ecc[7:6], hdr_parity(d) ^ ecc[5:0]};
    fixed = d;
    st    = 2'd0;
    if (syn != 8'd0) begin
      st  = 2'd2;
      hit = 1'b0;
      // One flipped parity bit (or reserved ECC bit): the data is intact.
      if ((syn & (syn - 8'd1)) == 8'd0) begin
        st = 2'd1;
      end else if (syn[7:6] == 2'b00) begin
        // One flipped data bit: its column equals the syndrome.
        for (int i = 0; i < 24; i++) begin
          col = {^(ECC_MASK5 & (24'd1 << i)), ^(ECC_MASK4 & (24'd1 << i)), ^(ECC_MASK3 & (24'd1 << i)),
                 ^(ECC_MASK2 & (24'd1 << i)), ^(ECC_MASK1 & (24'd1 << i)), ^(ECC_MASK0 & (24'd1 << i))};
          if (!hit && (col == syn[5:0])) begin
            hit      = 1'b1;
            fixed[i] = ~d[i];
            st       = 2'd1;
          end
        end
      end
    end
    hdr_ecc_check = {st, fixed};
  endfunction

  // CRC-16 over one byte.
  function automatic logic [15:0] crc16_byte(input logic [15:0] crc, input logic [7:0] b);
    logic [15:0] c;
    c = crc ^ {8'd0, b};
    for (int k = 0; k < 8; k++) c = c[0] ? ((c >> 1) ^ 16'h8408) : (c >> 1);
    crc16_byte = c;
  endfunction

endpackage
