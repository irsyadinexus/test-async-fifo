// -----------------------------------------------------------------------------
// tb_ahb_wrapper.sv
// Self-checking testbench for fifo_ahb_wrapper.
//
// Test sequence:
//   a) MODE reset value 0, register write/readback, AHB round trip, and the
//      raw-side pins ignored while the AHB owns both FIFO ports
//   b) AHB write until full, HREADYOUT stretching, abort, pop frees space,
//      retried write completes
//   c) AHB pop on empty stretches HREADYOUT, then completes after a push
//   d) MODE 1: AHB pushes, external rd_clk consumer pops; AHB reads return
//      zero without popping
//   e) MODE 2: external wr_clk producer pushes, AHB pops; AHB writes complete
//      but do not push
//   f) MODE 3: reads back as 3 and behaves as 0
//
// Clocking: hclk 100 MHz, cfg_clk 71 MHz, ext wr_clk 25 MHz, ext rd_clk 38 MHz.
// HREADY is wired to HREADYOUT (single-slave system).
//
// A stalled data phase (push while full, pop while empty) cannot be abandoned
// by a real AHB master. MODE 0 also gives the AHB engine the only push/pop
// path, so the wait-state tests abort the latched request with hresetn, which
// resets the AHB engine only; wr_rst_n/rd_rst_n are driven independently here
// so the FIFO contents survive. Production integrators tie them to hresetn and
// must poll config register 4 (full/empty) instead.
//
// Usage (Icarus Verilog):
//   iverilog -g2012 -o sim/tb_ahb_wrapper.vvp -I rtl \
//     rtl/async_fifo.sv rtl/fifo_apb_cfg.sv rtl/fifo_ahb_wrapper.sv \
//     tb/tb_ahb_wrapper.sv
//   vvp sim/tb_ahb_wrapper.vvp
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_ahb_wrapper;

  localparam int DW     = 8;
  localparam int DEPTH  = 16;
  localparam int ADDR_W = $clog2(DEPTH);

  localparam logic [1:0] HTRANS_IDLE   = 2'b00;
  localparam logic [1:0] HTRANS_NONSEQ = 2'b10;

  // --- AHB ---
  logic        hclk, hresetn;
  logic        hsel, hwrite, hreadyout, hresp;
  logic [1:0]  htrans;
  logic [2:0]  hsize;
  logic [31:0] haddr, hwdata, hrdata;

  // --- APB config ---
  logic        cfg_clk, cfg_presetn;
  logic        cfg_psel, cfg_penable, cfg_pwrite;
  logic [31:0] cfg_paddr, cfg_pwdata, cfg_prdata;
  logic        cfg_pready;

  // --- Raw side ---
  logic        wr_clk, wr_rst_n, rd_clk, rd_rst_n;
  logic        ext_wr_en;
  logic [DW-1:0] ext_wr_data;
  logic        ext_rd_en;
  logic [DW-1:0] ext_rd_data;

  // --- Status ---
  logic        full, empty, almost_full, almost_empty, irq;
  logic [ADDR_W:0] wr_ptr_gray_sync, rd_ptr_gray_sync;

  wire hready = hreadyout;   // single-slave system

  fifo_ahb_wrapper #(
    .DW    (DW),
    .DEPTH (DEPTH)
  ) dut (
    .hclk             (hclk),
    .hresetn          (hresetn),
    .hsel             (hsel),
    .haddr            (haddr),
    .htrans           (htrans),
    .hwrite           (hwrite),
    .hsize            (hsize),
    .hwdata           (hwdata),
    .hrdata           (hrdata),
    .hready           (hready),
    .hreadyout        (hreadyout),
    .hresp            (hresp),
    .cfg_clk          (cfg_clk),
    .cfg_presetn      (cfg_presetn),
    .cfg_psel         (cfg_psel),
    .cfg_penable      (cfg_penable),
    .cfg_pwrite       (cfg_pwrite),
    .cfg_paddr        (cfg_paddr),
    .cfg_pwdata       (cfg_pwdata),
    .cfg_prdata       (cfg_prdata),
    .cfg_pready       (cfg_pready),
    .wr_clk           (wr_clk),
    .wr_rst_n         (wr_rst_n),
    .rd_clk           (rd_clk),
    .rd_rst_n         (rd_rst_n),
    .ext_wr_en        (ext_wr_en),
    .ext_wr_data      (ext_wr_data),
    .ext_rd_en        (ext_rd_en),
    .ext_rd_data      (ext_rd_data),
    .full             (full),
    .empty            (empty),
    .almost_full      (almost_full),
    .almost_empty     (almost_empty),
    .irq              (irq),
    .wr_ptr_gray_sync (wr_ptr_gray_sync),
    .rd_ptr_gray_sync (rd_ptr_gray_sync)
  );

  // -----------------------------------------------------------------------
  // Clocks
  // -----------------------------------------------------------------------
  initial hclk = 0;
  always #5 hclk = ~hclk;            // 100 MHz

  initial cfg_clk = 0;
  always #7 cfg_clk = ~cfg_clk;      // ~71.4 MHz

  initial wr_clk = 0;
  always #20 wr_clk = ~wr_clk;       // 25 MHz

  initial rd_clk = 0;
  always #13 rd_clk = ~rd_clk;       // ~38.5 MHz

  // -----------------------------------------------------------------------
  // Scoreboard
  // -----------------------------------------------------------------------
  logic [DW-1:0] ref_mem [$];
  int            errors = 0;
  int            ahb_write_count = 0;
  int            ahb_read_count  = 0;

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
  // Reset: assert everything, then release all domains together (MODE returns
  // to 0 while the data-side resets are asserted, which is the documented
  // MODE-change procedure).
  // -----------------------------------------------------------------------
  task automatic do_reset;
    begin
      hresetn     <= 0;
      cfg_presetn <= 0;
      wr_rst_n    <= 0;
      rd_rst_n    <= 0;
      hsel        <= 0;
      htrans      <= HTRANS_IDLE;
      hwrite      <= 0;
      hsize       <= 3'b010;
      haddr       <= 0;
      hwdata      <= 0;
      cfg_psel    <= 0;
      cfg_penable <= 0;
      cfg_pwrite  <= 0;
      cfg_paddr   <= 0;
      cfg_pwdata  <= 0;
      ext_wr_en   <= 0;
      ext_wr_data <= 0;
      ext_rd_en   <= 0;
      ref_mem.delete();
      repeat (3) @(posedge hclk);
      repeat (3) @(posedge cfg_clk);
      hresetn     <= 1;
      cfg_presetn <= 1;
      wr_rst_n    <= 1;
      rd_rst_n    <= 1;
      repeat (4) @(posedge hclk);
      repeat (4) @(posedge cfg_clk);
      repeat (3) @(posedge wr_clk);
      repeat (3) @(posedge rd_clk);
    end
  endtask

  // -----------------------------------------------------------------------
  // APB config master BFM
  // -----------------------------------------------------------------------
  task automatic apb_cfg_write(input logic [3:0] off, input logic [31:0] data);
    begin
      @(posedge cfg_clk);
      cfg_psel <= 1; cfg_penable <= 0; cfg_pwrite <= 1;
      cfg_paddr <= {26'd0, off, 2'b00};
      cfg_pwdata <= data;
      @(posedge cfg_clk);
      cfg_penable <= 1;
      @(posedge cfg_clk);
      while (!cfg_pready) @(posedge cfg_clk);
      cfg_psel <= 0; cfg_penable <= 0; cfg_pwrite <= 0;
    end
  endtask

  task automatic apb_cfg_read(input logic [3:0] off, output logic [31:0] data);
    begin
      @(posedge cfg_clk);
      cfg_psel <= 1; cfg_penable <= 0; cfg_pwrite <= 0;
      cfg_paddr <= {26'd0, off, 2'b00};
      @(posedge cfg_clk);
      cfg_penable <= 1;
      @(posedge cfg_clk);
      while (!cfg_pready) @(posedge cfg_clk);
      data = cfg_prdata;
      cfg_psel <= 0; cfg_penable <= 0;
    end
  endtask

  // -----------------------------------------------------------------------
  // AHB master BFM (non-blocking drives at posedge, samples in the active
  // region of the completing edge)
  // -----------------------------------------------------------------------
  // One-cycle address phase, then IDLE while the data phase drains. HWDATA is
  // driven only in the data phase, as AHB requires.
  task automatic ahb_addr_phase(input bit wr);
    begin
      @(posedge hclk);
      hsel   <= 1;
      htrans <= HTRANS_NONSEQ;
      hwrite <= wr;
      haddr  <= 32'd0;
      @(posedge hclk);
      hsel   <= 0;
      htrans <= HTRANS_IDLE;
      hwrite <= 0;
    end
  endtask

  task automatic ahb_write(input logic [31:0] data);
    begin
      ahb_addr_phase(1'b1);
      hwdata <= data;
      @(posedge hclk);
      while (!hreadyout) @(posedge hclk);
      ahb_write_count++;
    end
  endtask

  task automatic ahb_read(output logic [31:0] data);
    begin
      ahb_addr_phase(1'b0);
      @(posedge hclk);
      while (!hreadyout) @(posedge hclk);
      data = hrdata;
      ahb_read_count++;
    end
  endtask

  // Abort a permanently stalled data phase by resetting the AHB engine only.
  task automatic ahb_abort_stalled;
    begin
      hsel   <= 0;
      htrans <= HTRANS_IDLE;
      hwrite <= 0;
      repeat (2) @(posedge hclk);
      hresetn <= 0;
      repeat (2) @(posedge hclk);
      hresetn <= 1;
      repeat (3) @(posedge hclk);
    end
  endtask

  task automatic ahb_write_probe_stall(input logic [31:0] data,
                                       input int min_stall, output int stalls);
    begin
      stalls = 0;
      ahb_addr_phase(1'b1);
      hwdata <= data;
      @(posedge hclk);
      while (!hreadyout && stalls < (min_stall + 4)) begin
        stalls++;
        @(posedge hclk);
      end
      if (stalls < min_stall)
        fail($sformatf("write: expected >= %0d wait states, saw %0d",
                       min_stall, stalls));
      ahb_abort_stalled;
    end
  endtask

  task automatic ahb_read_probe_stall(input int min_stall, output int stalls);
    begin
      stalls = 0;
      ahb_addr_phase(1'b0);
      @(posedge hclk);
      while (!hreadyout && stalls < (min_stall + 4)) begin
        stalls++;
        @(posedge hclk);
      end
      if (stalls < min_stall)
        fail($sformatf("read: expected >= %0d wait states, saw %0d",
                       min_stall, stalls));
      ahb_abort_stalled;
    end
  endtask

  // -----------------------------------------------------------------------
  // Raw-side BFM (used only in MODE 1 / MODE 2)
  // -----------------------------------------------------------------------
  task automatic ext_push(input logic [DW-1:0] data);
    begin
      @(posedge wr_clk);
      ext_wr_en   <= 1;
      ext_wr_data <= data;
      @(posedge wr_clk);
      ext_wr_en   <= 0;
      ref_mem.push_back(data);
    end
  endtask

  task automatic ext_pop(output logic [DW-1:0] data);
    begin
      @(posedge rd_clk);
      while (empty) @(posedge rd_clk);
      ext_rd_en <= 1;
      @(posedge rd_clk);
      ext_rd_en <= 0;
      #1 data = ext_rd_data;   // registered core read data updates at the edge
    end
  endtask

  task automatic ahb_push(input logic [DW-1:0] data);
    begin
      ahb_write({24'd0, data});
      ref_mem.push_back(data);
    end
  endtask

  task automatic ahb_pop(output logic [DW-1:0] data);
    logic [31:0] r;
    begin
      ahb_read(r);
      if (ref_mem.size() == 0) begin
        fail("pop on empty reference model");
        data = 'x;
      end else begin
        data = ref_mem.pop_front();
        if (r !== {24'd0, data}) begin
          $error("FAIL: ahb pop got 0x%08h expected 0x%08h", r,
                 {24'd0, data});
          errors++;
        end
      end
    end
  endtask

  // -----------------------------------------------------------------------
  // Tests
  // -----------------------------------------------------------------------
  task automatic test_mode0;
    logic [31:0] r, d;
    int i;
    begin
      $display("=== (a) MODE 0: AHB owns both ports ===");
      do_reset;
      apb_cfg_read(4'd9, r);
      expect32("MODE reset value", r, 32'd0);

      // Config register write/readback through the APB port
      apb_cfg_write(4'd1, 32'd5);
      apb_cfg_read(4'd1, r);
      expect32("reg1 readback", r, 32'd5);
      apb_cfg_write(4'd1, 32'((4 * DEPTH + 4) / 5));

      // Raw-side pins are ignored when the AHB owns the write port
      ext_wr_en   <= 1;
      ext_wr_data <= 8'h77;
      repeat (4) @(posedge wr_clk);
      ext_wr_en   <= 0;
      repeat (4) @(posedge hclk);
      apb_cfg_read(4'd6, r);            // approximate write occupancy
      expect32("ext write ignored in MODE 0", r, 32'd0);

      // AHB round trip
      for (i = 0; i < 5; i++) ahb_push(8'hA1 + i[7:0]);
      for (i = 0; i < 5; i++) begin
        logic [7:0] got;
        ahb_pop(got);
        if (got !== 8'hA1 + i[7:0]) begin
          $error("FAIL: MODE 0 order at %0d: got 0x%02h", i, got);
          errors++;
        end
      end
      repeat (8) @(posedge cfg_clk);   // let the pointer syncs settle
      apb_cfg_read(4'd6, d);
      expect32("occupancy after MODE 0 drain", d, 32'd0);
    end
  endtask

  task automatic test_full_stall;
    logic [31:0] r, d;
    logic [7:0]  got;
    int i, stalls;
    begin
      $display("=== (b) AHB write-while-full wait states ===");
      do_reset;
      for (i = 0; i < DEPTH; i++) ahb_push(8'h10 + i[7:0]);

      ahb_write_probe_stall(32'h0000_00EE, 3, stalls);
      if (stalls > 0) $display("  full stall: %0d wait states", stalls);

      // FIFO contents survived the engine reset; free one slot
      ahb_pop(got);
      if (got !== 8'h10) fail("first pop after stall mismatch");
      ahb_push(8'hEE);
      ahb_pop(got);
      if (got !== 8'h11) fail("second pop after retried push mismatch");

      // Drain the rest: 0x12..0x1F in order, then the retried 0xEE
      for (i = 0; i < DEPTH - 2; i++) begin
        ahb_pop(got);
        if (got !== 8'h12 + i[7:0]) begin
          $error("FAIL: post-stall drain at %0d: got 0x%02h expected 0x%02h",
                 i, got, 8'h12 + i[7:0]);
          errors++;
        end
      end
      ahb_pop(got);
      if (got !== 8'hEE) fail("retried push not at the tail");
      repeat (8) @(posedge cfg_clk);
      apb_cfg_read(4'd6, d);
      expect32("occupancy drained after stall test", d, 32'd0);
    end
  endtask

  task automatic test_empty_stall;
    logic [31:0] d;
    logic [7:0]  got;
    int stalls;
    begin
      $display("=== (c) AHB pop-while-empty wait states ===");
      do_reset;
      ahb_read_probe_stall(3, stalls);
      if (stalls > 0) $display("  empty stall: %0d wait states", stalls);

      ahb_push(8'h5A);
      ahb_pop(got);
      if (got !== 8'h5A) fail("retried pop after stall mismatch");
      repeat (8) @(posedge cfg_clk);
      apb_cfg_read(4'd6, d);
      expect32("occupancy after empty-stall test", d, 32'd0);
    end
  endtask

  task automatic test_mode1;
    logic [31:0] r;
    logic [7:0]  got;
    int i;
    begin
      $display("=== (d) MODE 1: AHB push, external rd_clk pop ===");
      do_reset;
      rd_rst_n <= 0;                    // hold read side while switching clocks
      repeat (2) @(posedge hclk);
      apb_cfg_write(4'd9, 32'd1);
      apb_cfg_read(4'd9, r);
      expect32("MODE readback after switch", r, 32'd1);
      repeat (4) @(posedge rd_clk);
      rd_rst_n <= 1;
      repeat (6) @(posedge rd_clk);

      for (i = 0; i < 4; i++) ahb_push(8'hB0 + i[7:0]);
      for (i = 0; i < 4; i++) begin
        ext_pop(got);
        if (got !== 8'hB0 + i[7:0]) begin
          $error("FAIL: MODE 1 external pop at %0d: got 0x%02h", i, got);
          errors++;
        end
      end
      if (!empty) fail("FIFO not empty after MODE 1 external drain");

      // AHB reads must complete with zero data and must not pop
      ahb_push(8'hC7);
      ahb_read(r);
      expect32("MODE 1 AHB read returns 0", r, 32'd0);
      ext_pop(got);
      if (got !== 8'hC7) fail("MODE 1 AHB read popped the FIFO");
      apb_cfg_read(4'd9, r);
      expect32("MODE still 1", r, 32'd1);
    end
  endtask

  task automatic test_mode2;
    logic [31:0] r;
    logic [7:0]  got;
    int i;
    begin
      $display("=== (e) MODE 2: external wr_clk push, AHB pop ===");
      do_reset;
      wr_rst_n <= 0;                    // hold write side while switching clocks
      repeat (2) @(posedge hclk);
      apb_cfg_write(4'd9, 32'd2);
      apb_cfg_read(4'd9, r);
      expect32("MODE readback after switch", r, 32'd2);
      repeat (4) @(posedge wr_clk);
      wr_rst_n <= 1;
      repeat (6) @(posedge wr_clk);

      for (i = 0; i < 4; i++) ext_push(8'hE0 + i[7:0]);
      for (i = 0; i < 4; i++) begin
        ahb_pop(got);
        if (got !== 8'hE0 + i[7:0]) begin
          $error("FAIL: MODE 2 AHB pop at %0d: got 0x%02h", i, got);
          errors++;
        end
      end

      // AHB writes complete with no effect on the FIFO
      ahb_write(32'h0000_0099);
      repeat (8) @(posedge cfg_clk);
      apb_cfg_read(4'd6, r);
      expect32("MODE 2 AHB write did not push", r, 32'd0);
      if (!empty) fail("FIFO not empty after MODE 2 AHB write");
    end
  endtask

  task automatic test_mode3;
    logic [31:0] r;
    logic [7:0]  got;
    begin
      $display("=== (f) MODE 3 behaves as 0 ===");
      do_reset;
      wr_rst_n <= 0;
      rd_rst_n <= 0;
      repeat (2) @(posedge hclk);
      apb_cfg_write(4'd9, 32'd3);
      apb_cfg_read(4'd9, r);
      expect32("MODE 3 readback", r, 32'd3);
      repeat (4) @(posedge wr_clk);
      repeat (4) @(posedge rd_clk);
      wr_rst_n <= 1;
      rd_rst_n <= 1;
      repeat (4) @(posedge hclk);

      ahb_push(8'h3C);
      ahb_pop(got);
      if (got !== 8'h3C) fail("MODE 3 round trip mismatch");

      // Raw write pin must be ignored (MODE 3 behaves as MODE 0)
      ext_wr_en   <= 1;
      ext_wr_data <= 8'h55;
      repeat (4) @(posedge wr_clk);
      ext_wr_en   <= 0;
      repeat (8) @(posedge cfg_clk);
      apb_cfg_read(4'd6, r);
      expect32("MODE 3 ignores raw write port", r, 32'd0);
    end
  endtask

  // -----------------------------------------------------------------------
  // Main
  // -----------------------------------------------------------------------
  initial begin
    hresetn     = 0;
    cfg_presetn = 0;
    wr_rst_n    = 0;
    rd_rst_n    = 0;
    hsel        = 0;
    htrans      = HTRANS_IDLE;
    hwrite      = 0;
    hsize       = 3'b010;
    haddr       = 0;
    hwdata      = 0;
    cfg_psel    = 0;
    cfg_penable = 0;
    cfg_pwrite  = 0;
    cfg_paddr   = 0;
    cfg_pwdata  = 0;
    ext_wr_en   = 0;
    ext_wr_data = 0;
    ext_rd_en   = 0;

    $display("========================================");
    $display("  fifo_ahb_wrapper testbench (DW=%0d, DEPTH=%0d)", DW, DEPTH);
    $display("========================================");

    test_mode0;
    test_full_stall;
    test_empty_stall;
    test_mode1;
    test_mode2;
    test_mode3;

    $display("----------------------------------------");
    $display("  AHB writes: %0d", ahb_write_count);
    $display("  AHB reads:  %0d", ahb_read_count);
    $display("  Errors:     %0d", errors);
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
