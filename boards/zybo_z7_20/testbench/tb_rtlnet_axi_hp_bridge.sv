// Purpose: independently check 128-bit AXI4 to 64-bit AXI3 HP adaptation.
// Overview: byte-addressed memory and upstream byte oracle; all legal burst lengths,
//   masked/zero strobes, split bursts, IDs, stalled channels and error propagation.
// Revision: 11-14-2026. Initial self-checking bridge bench, no foreach loops.
`timescale 1ns/1ps
module tb_rtlnet_axi_hp_bridge;
  import rtlnet_tb_pkg::*;
  localparam int ID_W = 6;
  logic clk = 0;
  always #5.555 clk = ~clk;
  logic resetn = 0;
  logic [ID_W-1:0] s_awid = 0;
  logic [31:0] s_awaddr = 0;
  logic [7:0] s_awlen = 0;
  logic [2:0] s_awsize = 0;
  logic [1:0] s_awburst = 0;
  logic  s_awvalid = 0;
  wire  s_awready;
  logic [127:0] s_wdata = 0;
  logic [15:0] s_wstrb = 0;
  logic  s_wlast = 0;
  logic  s_wvalid = 0;
  wire  s_wready;
  wire [ID_W-1:0] s_bid;
  wire [1:0] s_bresp;
  wire  s_bvalid;
  logic  s_bready = 0;
  logic [ID_W-1:0] s_arid = 0;
  logic [31:0] s_araddr = 0;
  logic [7:0] s_arlen = 0;
  logic [2:0] s_arsize = 0;
  logic [1:0] s_arburst = 0;
  logic  s_arvalid = 0;
  wire  s_arready;
  wire [ID_W-1:0] s_rid;
  wire [127:0] s_rdata;
  wire [1:0] s_rresp;
  wire  s_rlast;
  wire  s_rvalid;
  logic  s_rready = 0;
  wire [ID_W-1:0] m_awid;
  wire [31:0] m_awaddr;
  wire [3:0] m_awlen;
  wire [2:0] m_awsize;
  wire [1:0] m_awburst;
  wire  m_awvalid;
  wire  m_awready;
  wire [ID_W-1:0] m_wid;
  wire [63:0] m_wdata;
  wire [7:0] m_wstrb;
  wire  m_wlast;
  wire  m_wvalid;
  wire  m_wready;
  logic [ID_W-1:0] m_bid = 0;
  logic [1:0] m_bresp = 0;
  logic  m_bvalid = 0;
  wire  m_bready;
  wire [ID_W-1:0] m_arid;
  wire [31:0] m_araddr;
  wire [3:0] m_arlen;
  wire [2:0] m_arsize;
  wire [1:0] m_arburst;
  wire  m_arvalid;
  wire  m_arready;
  wire [ID_W-1:0] m_rid;
  wire [63:0] m_rdata;
  wire [1:0] m_rresp;
  wire  m_rlast;
  wire  m_rvalid;
  wire  m_rready;
  rtlnet_axi_hp_bridge #(.ID_W(ID_W)) dut (
    .aclk(clk),
    .aresetn(resetn),
    .s_axi_awid(s_awid),
    .s_axi_awaddr(s_awaddr),
    .s_axi_awlen(s_awlen),
    .s_axi_awsize(s_awsize),
    .s_axi_awburst(s_awburst),
    .s_axi_awvalid(s_awvalid),
    .s_axi_awready(s_awready),
    .s_axi_wdata(s_wdata),
    .s_axi_wstrb(s_wstrb),
    .s_axi_wlast(s_wlast),
    .s_axi_wvalid(s_wvalid),
    .s_axi_wready(s_wready),
    .s_axi_bid(s_bid),
    .s_axi_bresp(s_bresp),
    .s_axi_bvalid(s_bvalid),
    .s_axi_bready(s_bready),
    .s_axi_arid(s_arid),
    .s_axi_araddr(s_araddr),
    .s_axi_arlen(s_arlen),
    .s_axi_arsize(s_arsize),
    .s_axi_arburst(s_arburst),
    .s_axi_arvalid(s_arvalid),
    .s_axi_arready(s_arready),
    .s_axi_rid(s_rid),
    .s_axi_rdata(s_rdata),
    .s_axi_rresp(s_rresp),
    .s_axi_rlast(s_rlast),
    .s_axi_rvalid(s_rvalid),
    .s_axi_rready(s_rready),
    .m_axi_awid(m_awid),
    .m_axi_awaddr(m_awaddr),
    .m_axi_awlen(m_awlen),
    .m_axi_awsize(m_awsize),
    .m_axi_awburst(m_awburst),
    .m_axi_awvalid(m_awvalid),
    .m_axi_awready(m_awready),
    .m_axi_wid(m_wid),
    .m_axi_wdata(m_wdata),
    .m_axi_wstrb(m_wstrb),
    .m_axi_wlast(m_wlast),
    .m_axi_wvalid(m_wvalid),
    .m_axi_wready(m_wready),
    .m_axi_bid(m_bid),
    .m_axi_bresp(m_bresp),
    .m_axi_bvalid(m_bvalid),
    .m_axi_bready(m_bready),
    .m_axi_arid(m_arid),
    .m_axi_araddr(m_araddr),
    .m_axi_arlen(m_arlen),
    .m_axi_arsize(m_arsize),
    .m_axi_arburst(m_arburst),
    .m_axi_arvalid(m_arvalid),
    .m_axi_arready(m_arready),
    .m_axi_rid(m_rid),
    .m_axi_rdata(m_rdata),
    .m_axi_rresp(m_rresp),
    .m_axi_rlast(m_rlast),
    .m_axi_rvalid(m_rvalid),
    .m_axi_rready(m_rready)
  );

  byte unsigned memory [0:16383];
  byte unsigned reference_memory [0:16383];
  logic write_active = 0;
  logic read_active = 0;
  integer write_addr = 0;
  integer read_addr = 0;
  integer write_left = 0;
  integer read_left = 0;
  logic [ID_W-1:0] write_id = 0;
  logic [ID_W-1:0] read_id = 0;
  logic aw_enable = 0;
  logic w_enable = 0;
  logic ar_enable = 0;
  logic r_enable = 0;
  logic inject_error = 0;
  integer child_writes = 0;
  integer child_reads = 0;
  logic [127:0] source_word;
  logic [15:0] source_strobes;
  integer checks_before;

  // The memory returns one 64-bit word; its storage is separate from the oracle.
  function automatic logic [63:0] memory_word(input integer address);
    logic [63:0] word_value;
    for (int k = 0; k < 8; k++) word_value[k*8 +: 8] = memory[address+k];
    return word_value;
  endfunction
  assign m_awready = resetn && !write_active && !m_bvalid && aw_enable;
  assign m_wready = resetn && write_active && w_enable;
  assign m_arready = resetn && !read_active && ar_enable;
  assign m_rid = read_id;
  assign m_rdata = memory_word(read_addr);
  assign m_rresp = (inject_error && !read_addr[3]) ? 2'b10 : 2'b00;
  assign m_rlast = (read_left == 1);
  assign m_rvalid = read_active && r_enable;

  // Read valid never withdraws while the bridge backpressures it.
  always @(negedge clk) begin
    aw_enable = ($urandom % 4) != 0;
    w_enable = ($urandom % 3) != 0;
    ar_enable = ($urandom % 4) != 0;
    if (!m_rvalid || m_rready) r_enable = ($urandom % 4) != 0;
    s_rready = ($urandom % 3) != 0;
    s_bready = ($urandom % 3) != 0;
  end

  // HP slave validates split geometry and WID, and applies the actual byte enables.
  always @(posedge clk) begin
    if (!resetn) begin
      write_active = 0;
      read_active = 0;
      m_bvalid <= 0;
      m_bid <= 0;
      m_bresp <= 0;
    end else begin
      if (m_bvalid && m_bready) m_bvalid <= 0;
      if (m_awvalid && m_awready) begin
        tb_check(m_awsize == 3 && m_awburst == 1, "HP write full-width INCR");
        tb_check((m_awaddr[11:0] + (m_awlen + 1)*8) <= 4096, "HP write page boundary");
        write_addr = m_awaddr;
        write_left = m_awlen + 1;
        write_id = m_awid;
        write_active = 1;
        child_writes++;
      end
      if (m_wvalid && m_wready) begin
        tb_check(m_wid == write_id, "AXI3 WID matches AWID");
        tb_check(m_wlast == (write_left == 1), "child WLAST");
        for (int k = 0; k < 8; k++) begin
          if (m_wstrb[k]) memory[write_addr+k] = m_wdata[k*8 +: 8];
        end
        write_addr += 8;
        write_left--;
        if (write_left == 0) begin
          write_active = 0;
          m_bvalid <= 1;
          m_bid <= write_id;
          m_bresp <= inject_error ? 2'b10 : 2'b00;
        end
      end
      if (m_arvalid && m_arready) begin
        tb_check(m_arsize == 3 && m_arburst == 1, "HP read full-width INCR");
        tb_check((m_araddr[11:0] + (m_arlen + 1)*8) <= 4096, "HP read page boundary");
        read_addr = m_araddr;
        read_left = m_arlen + 1;
        read_id = m_arid;
        read_active = 1;
        child_reads++;
      end else if (m_rvalid && m_rready) begin
        read_addr += 8;
        read_left--;
        if (read_left == 0) read_active = 0;
      end
    end
  end

  task automatic write_burst(input integer address, input integer beats, input integer identifier);
    integer before_children;
    before_children = child_writes;
    @(negedge clk);
    s_awaddr = address;
    s_awid = identifier;
    s_awlen = beats - 1;
    s_awsize = 4;
    s_awburst = 1;
    s_awvalid = 1;
    do @(posedge clk); while (!s_awready);
    @(negedge clk);
    s_awvalid = 0;
    for (int beat = 0; beat < beats; beat++) begin
      source_word = {$urandom, $urandom, $urandom, $urandom};
      source_strobes = (beat % 4 == 0) ? 16'h0000 : ((beat % 4 == 1) ? 16'hffff : $urandom);
      s_wdata = source_word;
      s_wstrb = source_strobes;
      s_wlast = (beat == beats-1);
      s_wvalid = 1;
      do @(posedge clk); while (!s_wready);
      for (int k = 0; k < 16; k++) begin
        if (source_strobes[k]) reference_memory[address + beat*16 + k] = source_word[k*8 +: 8];
      end
      @(negedge clk);
      s_wvalid = 0;
      repeat ($urandom % 3) @(negedge clk);
    end
    do @(posedge clk); while (!(s_bvalid && s_bready));
    tb_check(s_bid == identifier, "upstream BID");
    tb_check(s_bresp == (inject_error ? 2'b10 : 2'b00), "aggregate BRESP");
    tb_check(child_writes - before_children == (beats > 8 ? 2 : 1), "write split count");
    for (int k = 0; k < 16384; k++) tb_check(memory[k] == reference_memory[k], "masked byte ownership");
  endtask

  task automatic read_burst(input integer address, input integer beats, input integer identifier);
    integer before_children;
    before_children = child_reads;
    @(negedge clk);
    s_araddr = address;
    s_arid = identifier;
    s_arlen = beats - 1;
    s_arsize = 4;
    s_arburst = 1;
    s_arvalid = 1;
    do @(posedge clk); while (!s_arready);
    @(negedge clk);
    s_arvalid = 0;
    for (int beat = 0; beat < beats; beat++) begin
      do @(posedge clk); while (!(s_rvalid && s_rready));
      tb_check(s_rid == identifier, "upstream RID");
      tb_check(s_rlast == (beat == beats-1), "joined RLAST");
      tb_check(s_rresp == (inject_error ? 2'b10 : 2'b00), "joined RRESP");
      for (int k = 0; k < 16; k++)
        tb_check(s_rdata[k*8 +: 8] == reference_memory[address + beat*16 + k], "joined read bytes");
      @(negedge clk);
    end
    tb_check(child_reads - before_children == (beats > 8 ? 2 : 1), "read split count");
  endtask

  initial begin
    for (int k = 0; k < 16384; k++) begin
      memory[k] = (k ^ (k >> 4)) & 255;
      reference_memory[k] = memory[k];
    end
    repeat (5) @(negedge clk);
    resetn = 1;
    for (int n = 1; n <= 16; n++) begin
      write_burst(n*512, n, n+3);
      read_burst(n*512, n, n+21);
    end
    write_burst(3840, 16, 63);
    read_burst(3840, 16, 62);
    inject_error = 1;
    write_burst(12288, 16, 51);
    read_burst(12288, 16, 52);
    inject_error = 0;
    fork
      write_burst(14336, 16, 53);
      read_burst(12288, 16, 54);
    join
    repeat (5) @(negedge clk);
    tb_verdict("tb_rtlnet_axi_hp_bridge");
  end
  initial begin
    #2000000;
    tb_error("watchdog");
    tb_verdict("tb_rtlnet_axi_hp_bridge");
  end
endmodule
