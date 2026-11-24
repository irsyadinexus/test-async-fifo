// -----------------------------------------------------------------------------
// tb_axis_wrapper.sv
// Self-checking testbench for fifo_axis_wrapper (AXI-Stream + AXI4-Lite).
//
// Test sequence:
//   a) Configuration reset values read through the AXI4-Lite slave
//   b) AXI4-Lite register write/readback (register 1) and mask readback
//   c) 32-word stream across unrelated s_axis/m_axis clocks, order checked
//   d) 50-cycle mid-stream m_axis backpressure, no loss and no duplication
//   e) Fill until s_axis_tready deasserts (full), then drain and verify
//   f) Drain until m_axis_tvalid deasserts (empty)
//   g) Throughput: m_axis_tvalid high on >= 9 of 10 consecutive cycles
//   h) IRQ through the register-3 mask and the almost-full threshold
//
// Clocking: aclk 83 MHz, s_axis_aclk 100 MHz, m_axis_aclk 71 MHz.
//
// Usage (Icarus Verilog):
//   iverilog -g2012 -o sim/tb_axis_wrapper.vvp -I rtl \
//     rtl/async_fifo.sv rtl/fifo_axis_wrapper.sv tb/tb_axis_wrapper.sv
//   vvp sim/tb_axis_wrapper.vvp
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_axis_wrapper;

  localparam int DW     = 8;
  localparam int DEPTH  = 16;
  localparam int ADDR_W = $clog2(DEPTH);

  // --- AXI4-Lite ---
  logic        aclk, aresetn;
  logic [31:0] awaddr, wdata, araddr, rdata;
  logic        awvalid, awready, wvalid, wready, bvalid, bready;
  logic [1:0]  bresp;
  logic        arvalid, arready, rvalid, rready;
  logic [1:0]  rresp;

  // --- Streams ---
  logic        s_axis_aclk, s_axis_aresetn, s_axis_tvalid, s_axis_tready;
  logic [DW-1:0] s_axis_tdata;
  logic        m_axis_aclk, m_axis_aresetn, m_axis_tvalid, m_axis_tready;
  logic [DW-1:0] m_axis_tdata;

  // --- Status ---
  logic        irq, almost_full, almost_empty;
  logic [ADDR_W:0] wr_ptr_gray_sync, rd_ptr_gray_sync;

  fifo_axis_wrapper #(
    .DW    (DW),
    .DEPTH (DEPTH)
  ) dut (
    .aclk             (aclk),
    .aresetn          (aresetn),
    .awaddr           (awaddr),
    .awvalid          (awvalid),
    .awready          (awready),
    .wdata            (wdata),
    .wvalid           (wvalid),
    .wready           (wready),
    .bresp            (bresp),
    .bvalid           (bvalid),
    .bready           (bready),
    .araddr           (araddr),
    .arvalid          (arvalid),
    .arready          (arready),
    .rdata            (rdata),
    .rresp            (rresp),
    .rvalid           (rvalid),
    .rready           (rready),
    .s_axis_aclk      (s_axis_aclk),
    .s_axis_aresetn   (s_axis_aresetn),
    .s_axis_tvalid    (s_axis_tvalid),
    .s_axis_tdata     (s_axis_tdata),
    .s_axis_tready    (s_axis_tready),
    .m_axis_aclk      (m_axis_aclk),
    .m_axis_aresetn   (m_axis_aresetn),
    .m_axis_tvalid    (m_axis_tvalid),
    .m_axis_tdata     (m_axis_tdata),
    .m_axis_tready    (m_axis_tready),
    .irq              (irq),
    .almost_full      (almost_full),
    .almost_empty     (almost_empty),
    .wr_ptr_gray_sync (wr_ptr_gray_sync),
    .rd_ptr_gray_sync (rd_ptr_gray_sync)
  );

  // -----------------------------------------------------------------------
  // Clocks: unrelated frequencies
  // -----------------------------------------------------------------------
  initial aclk = 0;
  always #6 aclk = ~aclk;                // ~83 MHz

  initial s_axis_aclk = 0;
  always #5 s_axis_aclk = ~s_axis_aclk;  // 100 MHz

  initial m_axis_aclk = 0;
  always #7 m_axis_aclk = ~m_axis_aclk;  // ~71 MHz

  // -----------------------------------------------------------------------
  // Scoreboard
  // -----------------------------------------------------------------------
  logic [DW-1:0] exp_q [$];    // words handed to s_axis
  logic [DW-1:0] mon_q [$];    // words accepted on m_axis
  int            errors = 0;
  int            rx_count = 0;
  int            tx_count = 0;

  always @(posedge m_axis_aclk) begin
    if (m_axis_tvalid && m_axis_tready) begin
      mon_q.push_back(m_axis_tdata);
      rx_count = rx_count + 1;
    end
  end

  task automatic fail(input string msg);
    begin
      $error("FAIL: %s", msg);
      errors++;
    end
  endtask

  task automatic expect32(input string label, input logic [31:0] got,
                          input logic [31:0] exp);
    begin
      if (got !== exp) begin
        $error("FAIL: %s: got 0x%08h expected 0x%08h", label, got, exp);
        errors++;
      end
    end
  endtask

  // -----------------------------------------------------------------------
  // Reset
  // -----------------------------------------------------------------------
  task automatic do_reset;
    begin
      aresetn          <= 0;
      s_axis_aresetn   <= 0;
      m_axis_aresetn   <= 0;
      awaddr           <= 0;
      awvalid          <= 0;
      wdata            <= 0;
      wvalid           <= 0;
      bready           <= 0;
      araddr           <= 0;
      arvalid          <= 0;
      rready           <= 0;
      s_axis_tvalid    <= 0;
      s_axis_tdata     <= 0;
      m_axis_tready    <= 0;
      exp_q.delete();
      mon_q.delete();
      rx_count = 0;
      tx_count = 0;
      repeat (3) @(posedge aclk);
      repeat (3) @(posedge s_axis_aclk);
      repeat (3) @(posedge m_axis_aclk);
      aresetn          <= 1;
      s_axis_aresetn   <= 1;
      m_axis_aresetn   <= 1;
      repeat (4) @(posedge aclk);
      repeat (4) @(posedge s_axis_aclk);
      repeat (4) @(posedge m_axis_aclk);
      m_axis_tready <= 1;
      repeat (2) @(posedge m_axis_aclk);
    end
  endtask

  // -----------------------------------------------------------------------
  // AXI4-Lite master BFM
  // -----------------------------------------------------------------------
  task automatic axil_write(input logic [3:0] off, input logic [31:0] data);
    bit aw_done, w_done;
    begin
      @(posedge aclk);
      awaddr  <= {26'd0, off, 2'b00};
      awvalid <= 1;
      wdata   <= data;
      wvalid  <= 1;
      aw_done = 0;
      w_done  = 0;
      while (!aw_done || !w_done) begin
        @(posedge aclk);
        if (!aw_done && awready) begin awvalid <= 0; aw_done = 1; end
        if (!w_done  && wready)  begin wvalid  <= 0; w_done  = 1; end
      end
      while (!bvalid) @(posedge aclk);
      bready <= 1;
      @(posedge aclk);
      bready <= 0;
    end
  endtask

  task automatic axil_read(input logic [3:0] off, output logic [31:0] data);
    begin
      @(posedge aclk);
      araddr  <= {26'd0, off, 2'b00};
      arvalid <= 1;
      forever begin
        @(posedge aclk);
        if (arready) break;
      end
      arvalid <= 0;
      while (!rvalid) @(posedge aclk);
      data = rdata;
      rready <= 1;
      @(posedge aclk);
      rready <= 0;
    end
  endtask

  // -----------------------------------------------------------------------
  // AXIS source / sink helpers
  // -----------------------------------------------------------------------
  task automatic axis_push(input logic [DW-1:0] data);
    begin
      @(posedge s_axis_aclk);
      s_axis_tvalid <= 1;
      s_axis_tdata  <= data;
      @(posedge s_axis_aclk);
      while (!s_axis_tready) @(posedge s_axis_aclk);
      s_axis_tvalid <= 0;
      exp_q.push_back(data);
      tx_count++;
    end
  endtask

  // Single-cycle push attempt: reports whether the handshake happened, so a
  // full FIFO cannot wedge the test.
  task automatic axis_try_push(input logic [DW-1:0] data, output bit accepted);
    begin
      @(posedge s_axis_aclk);
      s_axis_tvalid <= 1;
      s_axis_tdata  <= data;
      @(posedge s_axis_aclk);
      if (s_axis_tready) begin
        accepted = 1;
        exp_q.push_back(data);
        tx_count++;
      end else begin
        accepted = 0;
      end
      s_axis_tvalid <= 0;
    end
  endtask

  // Wait until at least n words have been accepted on m_axis.
  task automatic wait_rx(input int n);
    begin
      while (rx_count < n) @(posedge m_axis_aclk);
    end
  endtask

  task automatic check_stream(input string label);
    int n_exp;
    int n_got;
    begin
      n_exp = exp_q.size();
      n_got = mon_q.size();
      if (n_got !== n_exp) begin
        $error("FAIL: %s: received %0d words, expected %0d", label, n_got, n_exp);
        errors++;
      end else begin
        for (int i = 0; i < n_exp; i++) begin
          if (mon_q[i] !== exp_q[i]) begin
            $error("FAIL: %s: word %0d = 0x%02h expected 0x%02h",
                   label, i, mon_q[i], exp_q[i]);
            errors++;
          end
        end
      end
    end
  endtask

  // -----------------------------------------------------------------------
  // Tests
  // -----------------------------------------------------------------------
  task automatic test_reset_values;
    logic [31:0] d;
    begin
      $display("=== (a) AXI4-Lite configuration reset values ===");
      do_reset;
      axil_read(4'd0, d);
      expect32("reg0 almost-empty default", d, 32'((DEPTH + 4) / 5));
      axil_read(4'd1, d);
      expect32("reg1 almost-full default", d, 32'((4 * DEPTH + 4) / 5));
      axil_read(4'd2, d);
      expect32("reg2 active depth default", d, 32'(DEPTH));
      axil_read(4'd8, d);
      expect32("reg8 flush status reset", d, 32'd0);
    end
  endtask

  task automatic test_register_rw;
    logic [31:0] d;
    begin
      $display("=== (b) AXI4-Lite register write/readback ===");
      do_reset;
      axil_write(4'd1, 32'd5);
      axil_read(4'd1, d);
      expect32("reg1 readback", d, 32'd5);
      axil_write(4'd1, 32'((4 * DEPTH + 4) / 5));
      axil_read(4'd1, d);
      expect32("reg1 restored", d, 32'((4 * DEPTH + 4) / 5));
      axil_write(4'd3, 32'hF);
      axil_read(4'd3, d);
      expect32("reg3 mask readback", d, 32'hF);
      axil_write(4'd3, 32'h0);
    end
  endtask

  task automatic test_stream_order;
    int i;
    begin
      $display("=== (c) 32-word stream across s/m clocks ===");
      do_reset;
      for (i = 0; i < 32; i++) axis_push(8'h10 + i[7:0]);
      wait_rx(32);
      check_stream("stream order");
    end
  endtask

  task automatic test_backpressure;
    int i;
    begin
      $display("=== (d) 50-cycle mid-stream m_axis backpressure ===");
      do_reset;
      fork
        begin
          for (i = 0; i < 32; i++) axis_push(8'h40 + i[7:0]);
        end
        begin
          wait_rx(12);
          m_axis_tready <= 0;
          repeat (50) @(posedge m_axis_aclk);
          m_axis_tready <= 1;
        end
      join
      wait_rx(32);
      check_stream("backpressure stream");
    end
  endtask

  task automatic test_fill_full;
    int pushes, i;
    bit ok;
    begin
      $display("=== (e)/(f) fill until full, then drain until empty ===");
      do_reset;
      m_axis_tready <= 0;            // sink holds the pipeline
      pushes = 0;
      for (i = 0; i < DEPTH + 8; i++) begin
        axis_try_push(8'h80 + i[7:0], ok);
        if (!ok) break;
        pushes++;
      end
      axis_try_push(8'hFF, ok);      // must be refused while full
      if (ok) fail("push accepted while full");
      repeat (4) @(posedge s_axis_aclk);
      if (s_axis_tready) fail("s_axis_tready still high when full");
      if (pushes < DEPTH) fail("could not push DEPTH words before full");
      $display("  accepted %0d words before full", pushes);

      m_axis_tready <= 1;
      wait_rx(pushes);
      check_stream("fill/drain");
      repeat (4) @(posedge m_axis_aclk);
      if (m_axis_tvalid) fail("m_axis_tvalid still high after drain");
    end
  endtask

  task automatic test_throughput;
    int valid_cycles, i;
    begin
      $display("=== (g) m_axis throughput spot check ===");
      do_reset;
      m_axis_tready <= 0;
      for (i = 0; i < DEPTH; i++) axis_push(8'hC0 + i[7:0]);
      m_axis_tready <= 1;
      valid_cycles = 0;
      for (i = 0; i < 10; i++) begin
        @(posedge m_axis_aclk);
        if (m_axis_tvalid) valid_cycles++;
      end
      $display("  m_axis_tvalid high in %0d of 10 cycles", valid_cycles);
      if (valid_cycles < 9) fail("m_axis throughput below 9/10 cycles");
      wait_rx(DEPTH);
      check_stream("throughput drain");
    end
  endtask

  task automatic test_irq;
    logic [31:0] d;
    int i;
    begin
      $display("=== (h) IRQ through mask and almost-full ===");
      do_reset;
      m_axis_tready <= 0;
      axil_write(4'd3, 32'h4);       // mask almost-full only
      // The two-entry output pipeline absorbs two words, so DEPTH-1 pushes
      // leave DEPTH-3 entries in the FIFO, just above the almost-full
      // threshold of ceil(80% x DEPTH).
      for (i = 0; i < DEPTH - 1; i++) axis_push(8'hE0 + i[7:0]);
      repeat (8) @(posedge s_axis_aclk);
      if (!almost_full) fail("almost_full not asserted at threshold");
      if (dut.full)     fail("FIFO full before the almost-full check");
      repeat (8) @(posedge aclk);
      if (!irq)         fail("irq not asserted for masked almost-full");
      axil_read(4'd4, d);
      if (!d[2]) fail("almost-full status bit not set");
      axil_write(4'd3, 32'h0);
      repeat (6) @(posedge aclk);
      if (irq) fail("irq still asserted after masking");
      m_axis_tready <= 1;
      wait_rx(DEPTH - 1);
      check_stream("irq drain");
      repeat (8) @(posedge aclk);
      if (almost_full) fail("almost_full still asserted after drain");
    end
  endtask

  // -----------------------------------------------------------------------
  // Main
  // -----------------------------------------------------------------------
  initial begin
    aresetn          = 0;
    s_axis_aresetn   = 0;
    m_axis_aresetn   = 0;
    awaddr           = 0;
    awvalid          = 0;
    wdata            = 0;
    wvalid           = 0;
    bready           = 0;
    araddr           = 0;
    arvalid          = 0;
    rready           = 0;
    s_axis_tvalid    = 0;
    s_axis_tdata     = 0;
    m_axis_tready    = 0;

    $display("========================================");
    $display("  fifo_axis_wrapper testbench (DW=%0d, DEPTH=%0d)", DW, DEPTH);
    $display("========================================");

    test_reset_values;
    test_register_rw;
    test_stream_order;
    test_backpressure;
    test_fill_full;
    test_throughput;
    test_irq;

    $display("----------------------------------------");
    $display("  Stream words in:  %0d", tx_count);
    $display("  Stream words out: %0d", rx_count);
    $display("  Errors:           %0d", errors);
    $display("========================================");
    if (errors == 0)
      $display("  *** ALL TESTS PASSED ***");
    else
      $display("  *** TESTS FAILED ***");
    $display("========================================");
    $finish;
  end

  // Timeout watchdog
  initial begin
    #2000000;
    $error("TIMEOUT");
    $finish;
  end

endmodule
