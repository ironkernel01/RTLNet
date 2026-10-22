// -----------------------------------------------------------------------------
// File: rtlnet_udp_echo.sv
// Purpose: RTLNet UDP echo server, an application on the socket-layer streams
//   (documentation/rtlnet_architecture.md sections 7.7, 7.8, 15.5): every
//   datagram received on the selected socket (or on any socket) is sent back
//   to its sender unchanged.
// Overview:
//   * Input s_axis_* is the socket layer's m_axis_app_* (meta 0, meta 1,
//     payload); output m_axis_* goes to its s_axis_app_*.
//   * Echo: meta 0 is passed unchanged (the sender's IP and port become the
//     destination, the length is kept); meta 1 keeps the socket index and the
//     sender's MAC and has its flags byte cleared, so USE_SOCKET_REMOTE (bit 0)
//     is 0 and the metadata, not the socket registers, addresses the reply;
//     the payload beats pass through unchanged (cut-through, one beat per
//     clock while the socket layer accepts).
//   * Selection, sampled at each datagram's meta 1: CTRL.ENABLE and either
//     CTRL.SOCKET_ANY or meta 1 socket index == CTRL.SOCKET. A datagram that is
//     not echoed is consumed at full rate and counted in DISCARDED, so the
//     socket layer's RX FIFO never backs up behind a disabled echo.
//   * Back-pressure: the output is one rtlnet_axis_reg_slice; a stall on
//     m_axis stalls s_axis (s_axis_tready is the slice's registered ready
//     while a payload passes). The socket layer's transmit path drains
//     independently of its receive path, so no stall can deadlock.
//   * A malformed input datagram (meta 0 with tlast) is consumed and
//     discarded.
//   * Registers in app_clk behind an internal rtlnet_axil_cdc (s_axi_aclk to
//     app_clk) and rtlnet_axil_slave; offsets defined in
//     driver/rtlnet_udp_echo.h, mirrored by the localparams below.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: app_clk (streams, engine, register file); s_axi_aclk (AXI4-Lite
//   slave side of the crossing only).
// -----------------------------------------------------------------------------
module rtlnet_udp_echo (
  // Application clock and reset (synchronous, active low); the CPU register
  // clock and its reset (synchronous, active low, released with app_resetn
  // from the same assertion).
  input  logic        app_clk,
  input  logic        app_resetn,
  input  logic        s_axi_aclk,
  input  logic        s_axi_aresetn,

  // Received datagrams from the socket layer (its m_axis_app_*), app_clk:
  // meta 0, meta 1, payload.
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // Datagrams to send, to the socket layer (its s_axis_app_*), app_clk;
  // registered outputs.
  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,

  // AXI4-Lite register slave, s_axi_aclk domain, 12-bit byte address, 32-bit data.
  input  logic [11:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [11:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready
);

  import rtlnet_pkg::*;

  // ---------------------------------------------------------------------------
  // Register map: mirrors cores/rtlnet_udp_echo/driver/rtlnet_udp_echo.h.
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID               = 12'h000;
  localparam logic [11:0] REG_VERSION          = 12'h004;
  localparam logic [11:0] REG_CAPS             = 12'h008;
  localparam logic [11:0] REG_CTRL             = 12'h00C;
  localparam logic [11:0] REG_STATUS           = 12'h010;
  localparam logic [11:0] REG_ECHOED_DATAGRAMS = 12'h014;
  localparam logic [11:0] REG_ECHOED_BYTES     = 12'h018;
  localparam logic [11:0] REG_DISCARDED        = 12'h01C;

  localparam int CTRL_ENABLE_BIT     = 0;
  localparam int CTRL_SOCKET_ANY_BIT = 1;
  localparam int CTRL_SOCKET_LSB     = 8;
  localparam int CTRL_CNT_CLEAR_BIT  = 16;
  localparam int STATUS_ENABLE_BIT   = 0;
  localparam int STATUS_BUSY_BIT     = 1;

  localparam logic [31:0] CORE_ID      = id4("E", "C", "H", "O");
  localparam logic [31:0] CORE_VERSION = 32'h1022_2026;
  // CAPS: [15:0] largest datagram payload the socket layer carries.
  localparam logic [31:0] CORE_CAPS    = 32'd1472;

  // Metadata fields (architecture section 7.7).
  localparam int META1_SOCK_LSB = 56;
  localparam int META1_FLAG_LSB = 48;

  localparam logic [2:0] E_META0   = 3'd0;  // take meta 0
  localparam logic [2:0] E_META1   = 3'd1;  // take meta 1, decide echo or discard
  localparam logic [2:0] E_OUT0    = 3'd2;  // send meta 0
  localparam logic [2:0] E_OUT1    = 3'd3;  // send meta 1
  localparam logic [2:0] E_PAY     = 3'd4;  // pass the payload through
  localparam logic [2:0] E_DISCARD = 3'd5;  // consume the rest of a discarded datagram

  // ---------------------------------------------------------------------------
  // AXI4-Lite crossing and register strobes (app_clk)
  // ---------------------------------------------------------------------------
  logic [11:0] c_awaddr;
  logic        c_awvalid;
  logic        c_awready;
  logic [31:0] c_wdata;
  logic [3:0]  c_wstrb;
  logic        c_wvalid;
  logic        c_wready;
  logic [1:0]  c_bresp;
  logic        c_bvalid;
  logic        c_bready;
  logic [11:0] c_araddr;
  logic        c_arvalid;
  logic        c_arready;
  logic [31:0] c_rdata;
  logic [1:0]  c_rresp;
  logic        c_rvalid;
  logic        c_rready;
  logic        reg_wr_en;
  logic [11:0] reg_wr_addr;
  logic [31:0] reg_wr_data;
  logic        reg_rd_en;
  logic [11:0] reg_rd_addr;
  logic [31:0] reg_rd_data;

  // ---------------------------------------------------------------------------
  // Controls, counters, engine
  // ---------------------------------------------------------------------------
  logic        ctrl_enable;
  logic        ctrl_any;
  logic [7:0]  ctrl_socket;
  logic        cnt_clear;
  logic [31:0] status_word;
  logic [31:0] cnt_echoed;
  logic [31:0] cnt_bytes;
  logic [31:0] cnt_discarded;

  logic [2:0]  state;
  logic [63:0] meta0;
  logic [63:0] meta1;
  logic        meta1_last;
  logic        in_beat;
  logic        echo_this;
  logic        ev_echoed;
  logic        ev_discarded;
  logic [63:0] reply_meta1;

  logic [63:0] o_data;
  logic [7:0]  o_keep;
  logic        o_last;
  logic        o_valid;
  logic        o_ready;
  logic        o_fire;

  // CPU clock -> app_clk crossing of whole AXI4-Lite transactions.
  rtlnet_axil_cdc #(.ADDR_W(12)) u_axil_cdc (
    .s_clk         (s_axi_aclk),
    .s_resetn      (s_axi_aresetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .m_clk         (app_clk),
    .m_resetn      (app_resetn),
    .m_axi_awaddr  (c_awaddr),
    .m_axi_awvalid (c_awvalid),
    .m_axi_awready (c_awready),
    .m_axi_wdata   (c_wdata),
    .m_axi_wstrb   (c_wstrb),
    .m_axi_wvalid  (c_wvalid),
    .m_axi_wready  (c_wready),
    .m_axi_bresp   (c_bresp),
    .m_axi_bvalid  (c_bvalid),
    .m_axi_bready  (c_bready),
    .m_axi_araddr  (c_araddr),
    .m_axi_arvalid (c_arvalid),
    .m_axi_arready (c_arready),
    .m_axi_rdata   (c_rdata),
    .m_axi_rresp   (c_rresp),
    .m_axi_rvalid  (c_rvalid),
    .m_axi_rready  (c_rready)
  );

  // AXI4-Lite to register strobes in app_clk.
  rtlnet_axil_slave #(.ADDR_W(12)) u_axil_slave (
    .s_axi_aclk    (app_clk),
    .s_axi_aresetn (app_resetn),
    .s_axi_awaddr  (c_awaddr),
    .s_axi_awvalid (c_awvalid),
    .s_axi_awready (c_awready),
    .s_axi_wdata   (c_wdata),
    .s_axi_wstrb   (c_wstrb),
    .s_axi_wvalid  (c_wvalid),
    .s_axi_wready  (c_wready),
    .s_axi_bresp   (c_bresp),
    .s_axi_bvalid  (c_bvalid),
    .s_axi_bready  (c_bready),
    .s_axi_araddr  (c_araddr),
    .s_axi_arvalid (c_arvalid),
    .s_axi_arready (c_arready),
    .s_axi_rdata   (c_rdata),
    .s_axi_rresp   (c_rresp),
    .s_axi_rvalid  (c_rvalid),
    .s_axi_rready  (c_rready),
    .reg_wr_en     (reg_wr_en),
    .reg_wr_addr   (reg_wr_addr),
    .reg_wr_data   (reg_wr_data),
    .reg_rd_en     (reg_rd_en),
    .reg_rd_addr   (reg_rd_addr),
    .reg_rd_data   (reg_rd_data)
  );

  assign cnt_clear = reg_wr_en && (reg_wr_addr == REG_CTRL) && reg_wr_data[CTRL_CNT_CLEAR_BIT];

  always_comb begin
    status_word                    = '0;
    status_word[STATUS_ENABLE_BIT] = ctrl_enable;
    status_word[STATUS_BUSY_BIT]   = (state != E_META0);
  end

  // ---------------------------------------------------------------------------
  // Echo engine
  // ---------------------------------------------------------------------------
  assign in_beat   = s_axis_tvalid && s_axis_tready;
  assign echo_this = ctrl_enable && (ctrl_any || (s_axis_tdata[META1_SOCK_LSB +: 8] == ctrl_socket));
  assign o_fire    = o_valid && o_ready;

  always_comb begin
    reply_meta1                     = meta1;
    reply_meta1[META1_FLAG_LSB +: 8] = 8'h00;
  end

  // Input ready and output beat per state.
  always_comb begin
    s_axis_tready = 1'b0;
    o_valid       = 1'b0;
    o_data        = s_axis_tdata;
    o_keep        = s_axis_tkeep;
    o_last        = s_axis_tlast;
    case (state)
      E_META0, E_META1, E_DISCARD: s_axis_tready = 1'b1;
      E_OUT0: begin
        o_valid = 1'b1;
        o_data  = meta0;
        o_keep  = 8'hFF;
        o_last  = 1'b0;
      end
      E_OUT1: begin
        o_valid = 1'b1;
        o_data  = reply_meta1;
        o_keep  = 8'hFF;
        o_last  = meta1_last;
      end
      E_PAY: begin
        o_valid       = s_axis_tvalid;
        s_axis_tready = o_ready;
      end
      default: ;
    endcase
  end

  // Datagram sequencer: decide at meta 1, then echo or discard.
  always_ff @(posedge app_clk) begin
    if (!app_resetn) begin
      state        <= E_META0;
      meta0        <= '0;
      meta1        <= '0;
      meta1_last   <= 1'b0;
      ev_echoed    <= 1'b0;
      ev_discarded <= 1'b0;
    end else begin
      ev_echoed    <= 1'b0;
      ev_discarded <= 1'b0;
      case (state)
        E_META0: begin
          if (in_beat) begin
            meta0 <= s_axis_tdata;
            if (s_axis_tlast) ev_discarded <= 1'b1;
            else              state        <= E_META1;
          end
        end
        E_META1: begin
          if (in_beat) begin
            meta1      <= s_axis_tdata;
            meta1_last <= s_axis_tlast;
            if (echo_this) begin
              state <= E_OUT0;
            end else begin
              ev_discarded <= 1'b1;
              state        <= s_axis_tlast ? E_META0 : E_DISCARD;
            end
          end
        end
        E_OUT0: begin
          if (o_fire) state <= E_OUT1;
        end
        E_OUT1: begin
          if (o_fire) begin
            if (meta1_last) begin
              ev_echoed <= 1'b1;
              state     <= E_META0;
            end else begin
              state <= E_PAY;
            end
          end
        end
        E_PAY: begin
          if (in_beat && s_axis_tlast) begin
            ev_echoed <= 1'b1;
            state     <= E_META0;
          end
        end
        E_DISCARD: begin
          if (in_beat && s_axis_tlast) state <= E_META0;
        end
        default: state <= E_META0;
      endcase
    end
  end

  // Output register slice: every m_axis output is a flop.
  rtlnet_axis_reg_slice #(.DATA_W(64), .RESET_DATA(1'b1)) u_out_slice (
    .clk      (app_clk),
    .resetn   (app_resetn),
    .s_tdata  (o_data),
    .s_tkeep  (o_keep),
    .s_tlast  (o_last),
    .s_tvalid (o_valid),
    .s_tready (o_ready),
    .m_tdata  (m_axis_tdata),
    .m_tkeep  (m_axis_tkeep),
    .m_tlast  (m_axis_tlast),
    .m_tvalid (m_axis_tvalid),
    .m_tready (m_axis_tready)
  );

  // ---------------------------------------------------------------------------
  // Register file (app_clk)
  // ---------------------------------------------------------------------------
  // Controls and counters; CTRL changes apply from the next datagram's meta 1.
  always_ff @(posedge app_clk) begin
    if (!app_resetn) begin
      ctrl_enable   <= 1'b0;
      ctrl_any      <= 1'b0;
      ctrl_socket   <= '0;
      cnt_echoed    <= '0;
      cnt_bytes     <= '0;
      cnt_discarded <= '0;
    end else begin
      if (reg_wr_en && (reg_wr_addr == REG_CTRL)) begin
        ctrl_enable <= reg_wr_data[CTRL_ENABLE_BIT];
        ctrl_any    <= reg_wr_data[CTRL_SOCKET_ANY_BIT];
        ctrl_socket <= reg_wr_data[CTRL_SOCKET_LSB +: 8];
      end
      if (cnt_clear) begin
        cnt_echoed    <= '0;
        cnt_bytes     <= '0;
        cnt_discarded <= '0;
      end else begin
        if (ev_echoed) begin
          cnt_echoed <= cnt_echoed + 32'd1;
          cnt_bytes  <= cnt_bytes + {16'd0, meta0[15:0]};
        end
        if (ev_discarded) cnt_discarded <= cnt_discarded + 32'd1;
      end
    end
  end

  // Registered read mux: data the clock after reg_rd_en; undefined offsets read 0.
  always_ff @(posedge app_clk) begin
    if (!app_resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        REG_ID:               reg_rd_data <= CORE_ID;
        REG_VERSION:          reg_rd_data <= CORE_VERSION;
        REG_CAPS:             reg_rd_data <= CORE_CAPS;
        REG_CTRL:             reg_rd_data <= {16'd0, ctrl_socket, 6'd0, ctrl_any, ctrl_enable};
        REG_STATUS:           reg_rd_data <= status_word;
        REG_ECHOED_DATAGRAMS: reg_rd_data <= cnt_echoed;
        REG_ECHOED_BYTES:     reg_rd_data <= cnt_bytes;
        REG_DISCARDED:        reg_rd_data <= cnt_discarded;
        default:              reg_rd_data <= '0;
      endcase
    end
  end

endmodule
