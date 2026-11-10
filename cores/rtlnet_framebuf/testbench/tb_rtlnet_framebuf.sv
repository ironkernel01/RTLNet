// -----------------------------------------------------------------------------
// File: tb_rtlnet_framebuf.sv
// Purpose: self-checking bench for rtlnet_framebuf: slot ownership under a random writer, random reader take and release
//   and the firmware reader through the register window.
// Cases:
//   1. Writer: frames with random length, 85 percent good, in sequence; each slot request is checked against the bench's
//      own model: granted if and only if a slot exists that is neither "latest" nor held, and it is the first such slot
//      in rotation after the last one written. A frame that finds none is dropped and counted.
//   2. Safety (every clock): the slot the writer owns is never held by any reader and is never "latest"; every reference
//      count equals the number of holders of the slot.
//   3. Publish order and metadata: a good frame becomes "latest" with its frame number, timestamp, width, height and
//      source flag; a bad frame is counted and publishes nothing; a reader's take returns the slot that was latest in
//      the clock of its pulse (the previous one when a frame is published in the same clock) with that frame's metadata.
//   4. Readers: TB_NR external reader ports with random take, hold and release, a take with nothing published or while
//      holding is refused.
//   5. Firmware reader through the AXI4-Lite window (on its own clock through rtlnet_axil_cdc): take, poll, read the FW_*
//      registers (checked against the model), hold, read again (unchanged), release; errors (take with nothing published,
//      take while holding, release while not holding) set STATUS.FW_ERR, which clears by writing 1.
//   6. Final: PUBLISHED, DROPPED, BAD and FW_TAKES registers equal the model, REFCNT registers read 0 when every reader
//      has released, LATEST_* describe the last published frame, ID and CAPS read as documented.
// Defines: TB_N slots, TB_NR reader ports, TB_FRAMES writer frames, TB_SLOWREL 1 = readers hold long (forces drops).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_N
  `define TB_N 3
`endif
`ifndef TB_NR
  `define TB_NR 1
`endif
`ifndef TB_FRAMES
  `define TB_FRAMES 400
`endif
`ifndef TB_SLOWREL
  `define TB_SLOWREL 0
`endif

module tb_rtlnet_framebuf;

  import rtlnet_tb_pkg::*;

  localparam int          N         = `TB_N;
  localparam int          NR        = `TB_NR;
  localparam int          FRAMES    = `TB_FRAMES;
  localparam int          ADDR_W    = 29;
  localparam int          SLOT_LOG2 = 22;
  localparam logic [31:0] FB_BASE   = 32'h1000_0000;
  localparam int          RT        = NR + 1;

  logic clk     = 1'b0;
  logic cfg_clk = 1'b0;
  logic arstn   = 1'b0;
  logic resetn;
  logic cfg_resetn;

  always #5.0  clk     = ~clk;
  always #4.85 cfg_clk = ~cfg_clk;

  rtlnet_reset_sync u_rst_a (.clk(clk),     .arstn(arstn), .resetn(resetn));
  rtlnet_reset_sync u_rst_b (.clk(cfg_clk), .arstn(arstn), .resetn(cfg_resetn));

  // DUT ports.
  logic                  w_req = 1'b0;
  logic                  w_rsp_valid;
  logic                  w_rsp_ok;
  logic [ADDR_W-1:0]     w_rsp_base;
  logic                  w_done = 1'b0;
  logic                  w_done_good = 1'b0;
  logic [31:0]           w_done_frame_num = '0;
  logic [31:0]           w_done_timestamp = '0;
  logic [15:0]           w_done_width = '0;
  logic [15:0]           w_done_height = '0;
  logic                  w_done_src = 1'b0;
  logic [NR-1:0]         r_take = '0;
  logic [NR-1:0]         r_release = '0;
  logic [NR-1:0]         r_rsp_valid;
  logic [NR-1:0]         r_rsp_ok;
  logic [NR-1:0]         r_holds;
  logic [NR*8-1:0]       r_slot;
  logic [NR*ADDR_W-1:0]  r_base;
  logic [NR*32-1:0]      r_frame_num;
  logic [NR*32-1:0]      r_timestamp;
  logic [NR*16-1:0]      r_width;
  logic [NR*16-1:0]      r_height;
  logic [NR-1:0]         r_src;

  logic [11:0] awaddr, araddr;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;
  logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;

  rtlnet_tb_axil_master #(.ADDR_W(12)) u_mst (
    .aclk(cfg_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  rtlnet_framebuf #(
    .N(N), .NUM_READERS(NR), .ADDR_W(ADDR_W), .SLOT_LOG2(SLOT_LOG2), .FB_BASE(FB_BASE)
  ) dut (
    .clk(clk), .resetn(resetn), .s_axi_aclk(cfg_clk), .s_axi_aresetn(cfg_resetn),
    .w_req(w_req), .w_rsp_valid(w_rsp_valid), .w_rsp_ok(w_rsp_ok), .w_rsp_base(w_rsp_base),
    .w_done(w_done), .w_done_good(w_done_good), .w_done_frame_num(w_done_frame_num),
    .w_done_timestamp(w_done_timestamp), .w_done_width(w_done_width), .w_done_height(w_done_height),
    .w_done_src_pattern(w_done_src),
    .r_take(r_take), .r_release(r_release), .r_rsp_valid(r_rsp_valid), .r_rsp_ok(r_rsp_ok), .r_holds(r_holds),
    .r_slot(r_slot), .r_base(r_base), .r_frame_num(r_frame_num), .r_timestamp(r_timestamp), .r_width(r_width),
    .r_height(r_height), .r_src_pattern(r_src),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready));

  // ---------------------------------------------------------------------------
  // Random numbers (deterministic LCG)
  // ---------------------------------------------------------------------------
  int unsigned rng = 32'h1234_5678;

  function automatic int rnd(input int n);
    rng = rng * 32'd1103515245 + 32'd12345;
    return int'((rng >> 8) % n);
  endfunction

  // ---------------------------------------------------------------------------
  // Shadow model, updated every clock from the pins (and the holder state of the DUT for the firmware reader)
  // ---------------------------------------------------------------------------
  int          sh_latest;
  bit          sh_latest_valid;
  int          sh_latest_prev;          // "latest" as it was before the previous clock's publish
  bit          sh_latest_valid_prev;
  int          sh_last_wr;
  bit          sh_writing;
  int          sh_wr_slot;
  bit          sh_req_pending;
  bit          sh_exp_ok;
  int          sh_exp_slot;
  bit          w_req_d;
  longint      sh_published;
  longint      sh_dropped;
  longint      sh_bad;
  longint      sh_fw_takes;
  bit          sh_hold_d [RT];
  int          sh_meta_frame [N];
  int          sh_meta_ts [N];
  int          sh_meta_w [N];
  int          sh_meta_h [N];
  bit          sh_meta_src [N];
  longint      cycles;
  bit          fw_inflight;
  int          nr_takes;
  int          nr_refused;

  initial begin
    sh_latest = 0; sh_latest_valid = 0; sh_latest_prev = 0; sh_latest_valid_prev = 0;
    sh_last_wr = N - 1; sh_writing = 0; sh_wr_slot = 0; sh_req_pending = 0; sh_exp_ok = 0; sh_exp_slot = 0;
    w_req_d = 0; sh_published = 0; sh_dropped = 0; sh_bad = 0; sh_fw_takes = 0; cycles = 0;
    fw_inflight = 0; nr_takes = 0; nr_refused = 0;
    for (int i = 0; i < RT; i++) sh_hold_d[i] = 0;
    for (int i = 0; i < N; i++) begin
      sh_meta_frame[i] = 0; sh_meta_ts[i] = 0; sh_meta_w[i] = 0; sh_meta_h[i] = 0; sh_meta_src[i] = 0;
    end
  end

  function automatic int slot_of(input logic [ADDR_W-1:0] base);
    return int'((base - ADDR_W'(FB_BASE)) >> SLOT_LOG2);
  endfunction

  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      int held_mask;
      int free_mask;
      int refs [N];
      cycles++;
      // Holders: slot and hold state of every reader (the DUT's own registers) with this clock's release pulses applied.
      held_mask = 0;
      for (int i = 0; i < N; i++) refs[i] = 0;
      for (int r = 0; r < RT; r++) begin
        bit rel;
        rel = (r < NR) ? r_release[r] : dut.fw_release;
        if (dut.hold[r]) begin
          refs[int'(dut.hslot[r])]++;
          if (!rel) held_mask |= (1 << int'(dut.hslot[r]));
        end
      end
      // Invariant: every reference count equals the number of holders of the slot.
      for (int i = 0; i < N; i++) begin
        tb_check(int'(dut.refcnt[i]) == refs[i], $sformatf("refcnt[%0d]=%0d but %0d holders", i, int'(dut.refcnt[i]), refs[i]));
      end
      // Invariant: the slot the writer owns is never held and never latest.
      if (sh_writing) begin
        tb_check((refs[sh_wr_slot] == 0), $sformatf("writer owns slot %0d that a reader holds", sh_wr_slot));
        tb_check(!(sh_latest_valid && sh_latest == sh_wr_slot), $sformatf("writer owns the latest slot %0d", sh_wr_slot));
      end

      // Writer request: the model's expectation.
      if (w_req && !w_req_d) begin
        free_mask = ((1 << N) - 1) & ~held_mask;
        if (sh_latest_valid) free_mask &= ~(1 << sh_latest);
        sh_exp_ok = (free_mask != 0);
        sh_exp_slot = 0;
        for (int k = N; k >= 1; k--) begin
          int c;
          c = (sh_last_wr + k) % N;
          if (free_mask & (1 << c)) sh_exp_slot = c;
        end
        sh_req_pending = 1'b1;
      end
      w_req_d <= w_req;

      // Writer answer.
      if (w_rsp_valid) begin
        tb_check(sh_req_pending, "slot answer without a request");
        tb_check(w_rsp_ok == sh_exp_ok, $sformatf("slot answer ok=%0d, expected %0d", w_rsp_ok, sh_exp_ok));
        if (w_rsp_ok) begin
          tb_check(slot_of(w_rsp_base) == sh_exp_slot,
                   $sformatf("granted slot %0d, expected %0d (rotation)", slot_of(w_rsp_base), sh_exp_slot));
          tb_check(w_rsp_base == ADDR_W'(FB_BASE) + (ADDR_W'(slot_of(w_rsp_base)) << SLOT_LOG2), "slot base address");
          sh_writing = 1'b1;
          sh_wr_slot = slot_of(w_rsp_base);
          sh_last_wr = sh_wr_slot;
        end else begin
          sh_dropped++;
        end
        sh_req_pending = 1'b0;
      end

      // Reader answers (external ports): the slot that was latest in the clock of the pulse.
      for (int r = 0; r < NR; r++) begin
        if (r_rsp_valid[r]) begin
          if (r_rsp_ok[r]) begin
            int s;
            s = int'(r_slot[r*8 +: 8]);
            tb_check(sh_latest_valid_prev && s == sh_latest_prev, $sformatf("reader %0d took slot %0d, latest was %0d", r, s, sh_latest_prev));
            tb_check(int'(r_frame_num[r*32 +: 32]) == sh_meta_frame[s], "reader frame number");
            tb_check(int'(r_timestamp[r*32 +: 32]) == sh_meta_ts[s], "reader timestamp");
            tb_check(int'(r_width[r*16 +: 16]) == sh_meta_w[s], "reader width");
            tb_check(int'(r_height[r*16 +: 16]) == sh_meta_h[s], "reader height");
            tb_check(r_src[r] == sh_meta_src[s], "reader source flag");
            tb_check(r_base[r*ADDR_W +: ADDR_W] == ADDR_W'(FB_BASE) + (ADDR_W'(s) << SLOT_LOG2), "reader base address");
            nr_takes++;
          end else begin
            nr_refused++;
          end
        end
      end

      // Firmware takes: count the rising edges of its hold.
      if (dut.hold[NR] && !sh_hold_d[NR]) sh_fw_takes++;
      for (int r = 0; r < RT; r++) sh_hold_d[r] = dut.hold[r];

      // End of a frame.
      sh_latest_prev       = sh_latest;
      sh_latest_valid_prev = sh_latest_valid;
      if (w_done && sh_writing) begin
        sh_writing = 1'b0;
        if (w_done_good) begin
          sh_meta_frame[sh_wr_slot] = int'(w_done_frame_num);
          sh_meta_ts[sh_wr_slot]    = int'(w_done_timestamp);
          sh_meta_w[sh_wr_slot]     = int'(w_done_width);
          sh_meta_h[sh_wr_slot]     = int'(w_done_height);
          sh_meta_src[sh_wr_slot]   = w_done_src;
          sh_latest       = sh_wr_slot;
          sh_latest_valid = 1'b1;
          sh_published++;
        end else begin
          sh_bad++;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stimulus: writer
  // ---------------------------------------------------------------------------
  bit writer_done = 1'b0;
  int frame_no    = 0;

  task automatic writer_frame();
    bit good;
    int w;
    @(posedge clk);
    w_req <= 1'b1;
    @(posedge clk);
    while (!w_rsp_valid) @(posedge clk);
    w_req <= 1'b0;
    if (w_rsp_ok) begin
      repeat (rnd(40)) @(posedge clk);
      good = (rnd(100) < 85);
      w = (rnd(2) == 0) ? 1280 : 1920;
      frame_no++;
      w_done_frame_num <= 32'(frame_no * 3 + 1);
      w_done_timestamp <= 32'(cycles);
      w_done_width     <= 16'(w);
      w_done_height    <= (w == 1280) ? 16'd720 : 16'd1080;
      w_done_src       <= (rnd(2) == 0);
      w_done_good      <= good;
      w_done           <= 1'b1;
      @(posedge clk);
      w_done           <= 1'b0;
    end
    repeat (1 + rnd(12)) @(posedge clk);
  endtask

  initial begin
    wait (resetn === 1'b1);
    repeat (5) @(posedge clk);
    for (int f = 0; f < FRAMES; f++) writer_frame();
    repeat (20) @(posedge clk);
    writer_done = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Stimulus: external readers
  // ---------------------------------------------------------------------------
  genvar gr;
  generate
    for (gr = 0; gr < NR; gr++) begin : g_rd
      initial begin
        wait (resetn === 1'b1);
        repeat (3) @(posedge clk);
        // A take with nothing published is refused.
        while (!writer_done) begin
          @(posedge clk);
          r_take[gr] <= 1'b1;
          @(posedge clk);
          r_take[gr] <= 1'b0;
          while (!r_rsp_valid[gr]) @(posedge clk);
          if (r_rsp_ok[gr]) begin
            repeat (`TB_SLOWREL ? (20 + rnd(300)) : rnd(60)) @(posedge clk);
            // Release; sometimes also a take while holding (refused) and a release while not holding.
            if (rnd(6) == 0) begin
              r_take[gr] <= 1'b1;
              @(posedge clk);
              r_take[gr] <= 1'b0;
              while (!r_rsp_valid[gr]) @(posedge clk);
              tb_check(!r_rsp_ok[gr], "a take while holding was granted");
              repeat (2) @(posedge clk);
            end
            r_release[gr] <= 1'b1;
            @(posedge clk);
            r_release[gr] <= 1'b0;
          end
          repeat (rnd(40)) @(posedge clk);
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Stimulus: firmware reader through the register window
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID        = 12'h000;
  localparam logic [11:0] REG_CAPS      = 12'h008;
  localparam logic [11:0] REG_CTRL      = 12'h00C;
  localparam logic [11:0] REG_STATUS    = 12'h010;
  localparam logic [11:0] REG_FB_BASE   = 12'h014;
  localparam logic [11:0] REG_SLOT_B    = 12'h018;
  localparam logic [11:0] REG_L_BASE    = 12'h020;
  localparam logic [11:0] REG_L_FRAME   = 12'h024;
  localparam logic [11:0] REG_L_TS      = 12'h028;
  localparam logic [11:0] REG_L_WH      = 12'h02C;
  localparam logic [11:0] REG_L_SRC     = 12'h030;
  localparam logic [11:0] REG_F_BASE    = 12'h040;
  localparam logic [11:0] REG_F_FRAME   = 12'h044;
  localparam logic [11:0] REG_F_TS      = 12'h048;
  localparam logic [11:0] REG_F_WH      = 12'h04C;
  localparam logic [11:0] REG_F_SRC     = 12'h050;
  localparam logic [11:0] REG_PUB       = 12'h060;
  localparam logic [11:0] REG_DROP      = 12'h064;
  localparam logic [11:0] REG_BAD       = 12'h068;
  localparam logic [11:0] REG_TAKES     = 12'h06C;
  localparam logic [11:0] REG_REFCNT    = 12'h080;
  localparam logic [31:0] CTRL_TAKE     = 32'h0000_0001;
  localparam logic [31:0] CTRL_RELEASE  = 32'h0000_0002;
  localparam logic [31:0] CTRL_CLEAR    = 32'h0001_0000;
  localparam logic [31:0] ST_HOLDS      = 32'h0000_0002;
  localparam logic [31:0] ST_FW_ERR     = 32'h0000_0008;

  logic [31:0] rd_v;
  logic [1:0]  rd_resp;
  logic [1:0]  wr_resp;

  task automatic reg_read(input logic [11:0] a, output logic [31:0] v);
    u_mst.read32(a, v, rd_resp);
    tb_check(rd_resp == 2'b00, $sformatf("register read 0x%0h response %0d", a, rd_resp));
  endtask

  task automatic reg_write(input logic [11:0] a, input logic [31:0] v);
    u_mst.write32(a, v, 4'hF, wr_resp);
    tb_check(wr_resp == 2'b00, $sformatf("register write 0x%0h response %0d", a, wr_resp));
  endtask

  // Take for the firmware, poll for the result; returns 1 when it holds a slot.
  task automatic fw_take(output bit got);
    logic [31:0] st;
    got = 1'b0;
    reg_write(REG_CTRL, CTRL_TAKE);
    for (int i = 0; i < 40; i++) begin
      reg_read(REG_STATUS, st);
      if (st & ST_HOLDS) begin got = 1'b1; break; end
      if (st & ST_FW_ERR) break;
    end
  endtask

  task automatic fw_check_frame(input logic [31:0] st);
    logic [31:0] b, fr, ts, wh, src;
    int s;
    reg_read(REG_F_BASE, b);
    reg_read(REG_F_FRAME, fr);
    reg_read(REG_F_TS, ts);
    reg_read(REG_F_WH, wh);
    reg_read(REG_F_SRC, src);
    s = int'((b - FB_BASE) >> SLOT_LOG2);
    tb_check(int'(st[23:16]) == s, $sformatf("STATUS.FW_SLOT %0d, FW_BASE slot %0d", int'(st[23:16]), s));
    tb_check(s >= 0 && s < N, $sformatf("firmware slot %0d out of range", s));
    if (s >= 0 && s < N) begin
      tb_check(int'(fr) == sh_meta_frame[s], $sformatf("FW_FRAME %0d, model %0d", int'(fr), sh_meta_frame[s]));
      tb_check(int'(ts) == sh_meta_ts[s], "FW_TS");
      tb_check(int'(wh[15:0]) == sh_meta_w[s] && int'(wh[31:16]) == sh_meta_h[s], "FW_WH");
      tb_check(src[0] == sh_meta_src[s], "FW_SRC");
    end
  endtask

  int fw_ok_takes = 0;

  initial begin
    logic [31:0] st, v;
    bit got;
    wait (resetn === 1'b1 && cfg_resetn === 1'b1);
    repeat (10) @(posedge cfg_clk);
    // Header and geometry.
    reg_read(REG_ID, v);   tb_check(v == 32'h4642_5546, "ID is FBUF");
    reg_read(REG_CAPS, v); tb_check(v == {8'd0, 8'(ADDR_W), 8'(SLOT_LOG2), 4'(NR), 4'(N)}, $sformatf("CAPS 0x%0h", v));
    reg_read(REG_FB_BASE, v);  tb_check(v == FB_BASE, "FB_BASE");
    reg_read(REG_SLOT_B, v);   tb_check(v == (32'd1 << SLOT_LOG2), "SLOT_BYTES");
    // Nothing published yet: a take is refused and sets FW_ERR; a release while not holding too; W1C clears.
    reg_read(REG_STATUS, st);
    tb_check((st & ST_HOLDS) == 0, "firmware holds at reset");
    if (!sh_latest_valid) begin
      fw_take(got);
      tb_check(!got, "firmware took a slot with nothing published");
      reg_read(REG_STATUS, st);
      tb_check((st & ST_FW_ERR) != 0, "FW_ERR not set by a take with nothing published");
      reg_write(REG_STATUS, ST_FW_ERR);
      reg_read(REG_STATUS, st);
      tb_check((st & ST_FW_ERR) == 0, "FW_ERR did not clear");
      reg_write(REG_CTRL, CTRL_RELEASE);
      repeat (20) @(posedge cfg_clk);
      reg_read(REG_STATUS, st);
      tb_check((st & ST_FW_ERR) != 0, "FW_ERR not set by a release while not holding");
      reg_write(REG_STATUS, ST_FW_ERR);
    end
    // Random firmware reads while the writer runs.
    while (!writer_done) begin
      fw_take(got);
      if (got) begin
        fw_ok_takes++;
        reg_read(REG_STATUS, st);
        fw_check_frame(st);
        repeat (rnd(`TB_SLOWREL ? 400 : 80)) @(posedge cfg_clk);
        // Unchanged while held.
        reg_read(REG_STATUS, st);
        tb_check((st & ST_HOLDS) != 0, "firmware lost its slot while holding");
        fw_check_frame(st);
        if (rnd(5) == 0) begin
          reg_write(REG_CTRL, CTRL_TAKE);                 // take while holding: refused, flag set, hold kept
          repeat (20) @(posedge cfg_clk);
          reg_read(REG_STATUS, st);
          tb_check((st & ST_FW_ERR) != 0 && (st & ST_HOLDS) != 0, "take while holding: flag or hold wrong");
          reg_write(REG_STATUS, ST_FW_ERR);
        end
        reg_write(REG_CTRL, CTRL_RELEASE);
        repeat (20) @(posedge cfg_clk);
        reg_read(REG_STATUS, st);
        tb_check((st & ST_HOLDS) == 0, "firmware still holds after release");
      end else begin
        reg_write(REG_STATUS, ST_FW_ERR);
      end
      repeat (rnd(100)) @(posedge cfg_clk);
    end
    // Quiesce and compare the registers with the model.
    repeat (100) @(posedge cfg_clk);
    reg_read(REG_STATUS, st);
    if (st & ST_HOLDS) begin
      reg_write(REG_CTRL, CTRL_RELEASE);
      repeat (20) @(posedge cfg_clk);
    end
    // Let every reader finish: the external readers stop with the writer; give them time to release.
    repeat (400) @(posedge cfg_clk);
    reg_read(REG_PUB, v);  tb_check(longint'(v) == sh_published, $sformatf("PUBLISHED %0d, model %0d", v, sh_published));
    reg_read(REG_DROP, v); tb_check(longint'(v) == sh_dropped,   $sformatf("DROPPED %0d, model %0d", v, sh_dropped));
    reg_read(REG_BAD, v);  tb_check(longint'(v) == sh_bad,       $sformatf("BAD %0d, model %0d", v, sh_bad));
    reg_read(REG_TAKES, v); tb_check(longint'(v) == sh_fw_takes, $sformatf("FW_TAKES %0d, model %0d", v, sh_fw_takes));
    for (int i = 0; i < N; i++) begin
      reg_read(REG_REFCNT + 12'(4 * i), v);
      tb_check(v == 32'd0, $sformatf("REFCNT[%0d]=%0d after every holder released", i, v));
    end
    reg_read(REG_STATUS, st);
    tb_check((st & 32'h1) == 32'h1, "STATUS.LATEST_VALID");
    tb_check(int'(st[15:8]) == sh_latest, $sformatf("STATUS.LATEST_SLOT %0d, model %0d", int'(st[15:8]), sh_latest));
    reg_read(REG_L_BASE, v);  tb_check(v == FB_BASE + (32'(sh_latest) << SLOT_LOG2), "LATEST_BASE");
    reg_read(REG_L_FRAME, v); tb_check(int'(v) == sh_meta_frame[sh_latest], "LATEST_FRAME");
    reg_read(REG_L_TS, v);    tb_check(int'(v) == sh_meta_ts[sh_latest], "LATEST_TS");
    reg_read(REG_L_WH, v);    tb_check(int'(v[15:0]) == sh_meta_w[sh_latest] && int'(v[31:16]) == sh_meta_h[sh_latest], "LATEST_WH");
    reg_read(REG_L_SRC, v);   tb_check(v[0] == sh_meta_src[sh_latest], "LATEST_SRC");
    // Counter clear.
    reg_write(REG_CTRL, CTRL_CLEAR);
    reg_read(REG_PUB, v); tb_check(v == 32'd0, "PUBLISHED after CNT_CLEAR");
    // Coverage of the scenario.
    tb_check(sh_published > 30, $sformatf("only %0d frames published", sh_published));
    tb_check(sh_bad > 5, $sformatf("only %0d bad frames", sh_bad));
    tb_check(nr_takes > 5, $sformatf("only %0d external takes", nr_takes));
    tb_check(fw_ok_takes > 3, $sformatf("only %0d firmware takes", fw_ok_takes));
    if (`TB_SLOWREL) tb_check(sh_dropped > 0, "the slow-release scenario produced no dropped frame");
    $display("framebuf: published %0d dropped %0d bad %0d ext takes %0d (refused %0d) fw takes %0d", sh_published, sh_dropped,
             sh_bad, nr_takes, nr_refused, fw_ok_takes);
    tb_verdict("tb_rtlnet_framebuf");
  end

  // Watchdog.
  initial begin
    #20ms;
    tb_error("watchdog: the bench did not finish");
    tb_verdict("tb_rtlnet_framebuf");
  end

  initial begin
    repeat (8) #20;
    arstn = 1'b1;
  end

endmodule
