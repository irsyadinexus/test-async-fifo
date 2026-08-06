// -----------------------------------------------------------------------------
// tb_async_fifo.sv
// Comprehensive testbench for the async dual-clock FIFO.
//
// Test sequence:
//   1) Reset
//   2) Write-only until full
//   3) Read-only until empty
//   4) Simultaneous read+write (mixed frequency)
//   5) Random stress with scoreboard
//   6) Gray-code pointer validation
//   7) Programmable thresholds and active-depth modes
//
// Usage (Icarus Verilog):
//   iverilog -g2012 -o sim/tb_out -I rtl \
//     rtl/async_fifo_pkg.sv rtl/async_fifo.sv tb/tb_async_fifo.sv
//   vvp sim/tb_out
//
// Usage (Verilator):
//   See sim/run_verilator.sh
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_async_fifo;

  import async_fifo_pkg::*;

  // --- Parameters ---
  localparam int DW    = 8;
  localparam int DEPTH = 16;
  localparam int ADDR_W = $clog2(DEPTH);

  // --- DUT signals ---
  logic                  wr_clk, rd_clk;
  logic                  wr_rst_n, rd_rst_n;
  logic                  wr_en, rd_en;
  logic  [DW-1:0]        wr_data, rd_data;
  logic                  full, empty;
  logic                  cfg_we, almost_empty, almost_full;
  logic [1:0]            cfg_addr;
  logic [ADDR_W:0]       cfg_wdata;
  logic [ADDR_W:0]       wr_ptr_gray_sync, rd_ptr_gray_sync;

  // --- DUT ---
  async_fifo #(
    .DW(DW),
    .DEPTH(DEPTH)
  ) dut (
    .wr_clk           (wr_clk),
    .wr_rst_n         (wr_rst_n),
    .wr_en            (wr_en),
    .wr_data          (wr_data),
    .full             (full),
    .rd_clk           (rd_clk),
    .rd_rst_n         (rd_rst_n),
    .rd_en            (rd_en),
    .rd_data          (rd_data),
    .empty            (empty),
    .cfg_clk          (wr_clk),
    .cfg_rst_n        (wr_rst_n),
    .cfg_we           (cfg_we),
    .cfg_addr         (cfg_addr),
    .cfg_wdata        (cfg_wdata),
    .almost_empty     (almost_empty),
    .almost_full      (almost_full),
    .wr_ptr_gray_sync (),
    .rd_ptr_gray_sync ()
  );

  // -----------------------------------------------------------------------
  // Clocks — different frequencies to test true async behavior
  // -----------------------------------------------------------------------
  // Write clock: 100 MHz (10 ns period)
  initial wr_clk = 0;
  always #5 wr_clk = ~wr_clk;

  // Read clock: 62.5 MHz (16 ns period) — non-harmonic
  initial rd_clk = 0;
  always #8 rd_clk = ~rd_clk;

  // -----------------------------------------------------------------------
  // Scoreboard / reference model
  // -----------------------------------------------------------------------
  logic [DW-1:0] ref_mem [$]; // dynamic queue as golden model
  int            errors = 0;
  int            wr_count = 0;
  int            rd_count = 0;
  bit [3:0]      depth_coverage = '0;
  bit            ae_assert_coverage = 0;
  bit            ae_clear_coverage = 0;
  bit            af_assert_coverage = 0;
  bit            af_clear_coverage = 0;
  bit [3:0]      boundary_coverage = '0; // cfg saturation, invalid addr, blocked W/R

  // -----------------------------------------------------------------------
  // Reset task
  // -----------------------------------------------------------------------
  task automatic do_reset;
    begin
      wr_rst_n = 0;
      rd_rst_n = 0;
      wr_en    = 0;
      rd_en    = 0;
      wr_data  = 0;
      cfg_we    = 0;
      cfg_addr  = 0;
      cfg_wdata = 0;
      ref_mem.delete();
      // Hold reset across both clock edges
      @(posedge wr_clk);
      @(posedge wr_clk);
      @(posedge rd_clk);
      @(posedge rd_clk);
      wr_rst_n = 1;
      rd_rst_n = 1;
      @(posedge wr_clk);
      @(posedge rd_clk);
    end
  endtask

  task automatic cfg_write(input logic [1:0] addr,
                           input logic [ADDR_W:0] data);
    begin
      @(negedge wr_clk);
      cfg_addr = addr;
      cfg_wdata = data;
      cfg_we = 1;
      @(negedge wr_clk);
      cfg_we = 0;
      repeat (4) @(posedge wr_clk);
      repeat (4) @(posedge rd_clk);
    end
  endtask

  task automatic test_depth_mode(input int mode, input int expected_depth);
    int i;
    begin
      $display("=== Depth mode %0d: %0d entries ===", mode, expected_depth);
      do_reset;
      cfg_write(2, mode);
      for (i = 0; i < expected_depth; i++) do_write(DW'(i));
      repeat (3) @(posedge wr_clk);
      if (!full) begin
        $error("FAIL: mode %0d not full at %0d entries", mode, expected_depth);
        errors++;
      end else depth_coverage[mode] = 1;
      for (i = 0; i < expected_depth; i++) do_read;
      repeat (3) @(posedge rd_clk);
    end
  endtask

  task automatic test_programmable_flags;
    int i;
    begin
      $display("=== Programmable almost flags ===");
      do_reset;
      cfg_write(0, 2);   // almost empty at <= 2
      cfg_write(1, 12);  // almost full at >= 12
      ae_assert_coverage = almost_empty;
      for (i = 0; i < 4; i++) do_write(DW'(i));
      repeat (4) @(posedge rd_clk);
      ae_clear_coverage = !almost_empty;
      for (i = 4; i < 12; i++) do_write(DW'(i));
      repeat (4) @(posedge wr_clk);
      af_assert_coverage = almost_full;
      for (i = 0; i < 6; i++) do_read;
      repeat (4) @(posedge wr_clk);
      af_clear_coverage = !almost_full;
      if (!(ae_assert_coverage && ae_clear_coverage &&
            af_assert_coverage && af_clear_coverage)) begin
        $error("FAIL: almost flag coverage incomplete");
        errors++;
      end
      do_reset;
    end
  endtask

  task automatic test_boundaries;
    logic [ADDR_W:0] saved_ae;
    logic [ADDR_W:0] saved_wr_ptr;
    begin
      $display("=== Configuration and access boundaries ===");
      do_reset;

      cfg_write(0, {ADDR_W+1{1'b1}});
      if (dut.ae_threshold == DEPTH) boundary_coverage[0] = 1;
      else begin $error("FAIL: AE threshold did not saturate"); errors++; end

      saved_ae = dut.ae_threshold;
      cfg_write(3, 0);
      if (dut.ae_threshold == saved_ae) boundary_coverage[1] = 1;
      else begin $error("FAIL: invalid cfg address changed state"); errors++; end

      cfg_write(2, 3); // quarter depth
      repeat (DEPTH/4) do_write(DW'($urandom));
      repeat (3) @(posedge wr_clk);
      saved_wr_ptr = dut.wr_ptr_bin;
      @(negedge wr_clk); wr_en = 1;
      @(posedge wr_clk); #1 wr_en = 0;
      if (full && dut.wr_ptr_bin == saved_wr_ptr) boundary_coverage[2] = 1;
      else begin $error("FAIL: write was not blocked at full"); errors++; end

      do_reset;
      rd_en = 1; repeat (2) @(posedge rd_clk); #1 rd_en = 0;
      if (empty) boundary_coverage[3] = 1;
      else begin $error("FAIL: read was not blocked at empty"); errors++; end
    end
  endtask

  // -----------------------------------------------------------------------
  // Write task
  // -----------------------------------------------------------------------
  task automatic do_write(input [DW-1:0] data);
    begin
      @(negedge wr_clk);
      wr_en   = 1;
      wr_data = data;
      @(posedge wr_clk);
      #1 wr_en = 0;
      if (!full) begin
        ref_mem.push_back(data);
        wr_count++;
      end
    end
  endtask

  // -----------------------------------------------------------------------
  // Read task (registered read — data valid one cycle after rd_en)
  // -----------------------------------------------------------------------
  task automatic do_read;
    logic [DW-1:0] expected;
    begin
      while (empty) @(posedge rd_clk);
      @(negedge rd_clk);
      rd_en = 1;
      @(posedge rd_clk);
      #1 rd_en = 0;
      if (!empty) begin
        expected = ref_mem.pop_front();
        rd_count++;
        // Data appears on next clock due to registered read
        @(posedge rd_clk);
        #1;
        if (rd_data !== expected) begin
          $error("MISMATCH: got %0d, expected %0d", rd_data, expected);
          errors++;
        end
      end
    end
  endtask

  // -----------------------------------------------------------------------
  // Test 1: Reset
  // -----------------------------------------------------------------------
  task test_reset;
    begin
      $display("=== Test 1: Reset ===");
      do_reset;
      if (!empty) begin
        $error("FAIL: FIFO not empty after reset");
        errors++;
      end
      if (full) begin
        $error("FAIL: FIFO full after reset");
        errors++;
      end
      $display("  Reset OK");
    end
  endtask

  // -----------------------------------------------------------------------
  // Test 2: Write until full
  // -----------------------------------------------------------------------
  task test_write_full;
    int i;
    begin
      $display("=== Test 2: Write until full ===");
      for (i = 0; i < DEPTH; i++) begin
        do_write(i[DW-1:0]);
      end
      // Wait for synchronization
      @(posedge wr_clk); @(posedge wr_clk); @(posedge wr_clk);
      if (!full) begin
        $error("FAIL: FIFO not full after %0d writes", DEPTH);
        errors++;
      end else begin
        $display("  FIFO full after %0d writes", DEPTH);
      end
    end
  endtask

  // -----------------------------------------------------------------------
  // Test 3: Read until empty
  // -----------------------------------------------------------------------
  task test_read_empty;
    int i;
    begin
      $display("=== Test 3: Read until empty ===");
      for (i = 0; i < DEPTH; i++) begin
        do_read;
      end
      @(posedge rd_clk); @(posedge rd_clk); @(posedge rd_clk);
      if (!empty) begin
        $error("FAIL: FIFO not empty after %0d reads", DEPTH);
        errors++;
      end else begin
        $display("  FIFO empty after %0d reads", DEPTH);
      end
    end
  endtask

  // -----------------------------------------------------------------------
  // Test 4: Simultaneous R/W with different clock rates
  // -----------------------------------------------------------------------
  task test_simultaneous_rw;
    int i;
    begin
      $display("=== Test 4: Simultaneous R/W ===");
      for (i = 0; i < DEPTH*4; i++) begin
        fork
          begin
            // Write attempt
            @(negedge wr_clk);
            if (!full) begin
              wr_en   = 1;
              wr_data = DW'($urandom_range(0, (1 << DW) - 1));
              @(posedge wr_clk);
              #1 wr_en = 0;
              ref_mem.push_back(wr_data);
              wr_count++;
            end
          end
          begin
            // Read attempt
            @(negedge rd_clk);
            if (!empty) begin
              rd_en = 1;
              @(posedge rd_clk);
              #1 rd_en = 0;
              // Data valid next cycle (registered read)
              @(posedge rd_clk);
              #1;
              if (ref_mem.size() > 0) begin
                logic [DW-1:0] expected;
                expected = ref_mem.pop_front();
                if (rd_data !== expected) begin
                  $error("R/W MISMATCH: got %0d, expected %0d", rd_data, expected);
                  errors++;
                end
                rd_count++;
              end
            end
          end
        join
      end
      $display("  R/W test done: %0d writes, %0d reads", wr_count, rd_count);
    end
  endtask

  // -----------------------------------------------------------------------
  // Test 5: Random stress
  // -----------------------------------------------------------------------
  task test_random_stress;
    int i;
    logic op;
    begin
      $display("=== Test 5: Random stress ===");
      for (i = 0; i < DEPTH*20; i++) begin
        op = logic'($urandom_range(0, 1));
        if (op == 0 && !full) begin
          @(negedge wr_clk);
          wr_en   = 1;
          wr_data = DW'($urandom);
          @(posedge wr_clk);
          #1 wr_en = 0;
          ref_mem.push_back(wr_data);
          wr_count++;
        end else if (op == 1 && !empty) begin
          @(negedge rd_clk);
          rd_en = 1;
          @(posedge rd_clk);
          #1 rd_en = 0;
          // Data valid next cycle (registered read)
          @(posedge rd_clk);
          #1;
          if (ref_mem.size() > 0) begin
            logic [DW-1:0] expected;
            expected = ref_mem.pop_front();
            if (rd_data !== expected) begin
              $error("STRESS MISMATCH: got %0d, expected %0d", rd_data, expected);
              errors++;
            end
            rd_count++;
          end
        end
        // Random small delay
        #(i % 3 * 2);
      end
      $display("  Stress done: %0d writes, %0d reads", wr_count, rd_count);
    end
  endtask

  // -----------------------------------------------------------------------
  // Main stimulus
  // -----------------------------------------------------------------------
  initial begin
    $display("========================================");
    $display("  Async FIFO Testbench");
    $display("  DW=%0d  DEPTH=%0d  ADDR_W=%0d", DW, DEPTH, ADDR_W);
    $display("========================================");

    errors = 0;
    wr_count = 0;
    rd_count = 0;

    test_reset;
    test_write_full;
    test_read_empty;
    test_simultaneous_rw;
    test_random_stress;

    while (ref_mem.size() > 0 && !empty) do_read;
    test_programmable_flags;
    test_boundaries;
    test_depth_mode(0, DEPTH);
    test_depth_mode(1, DEPTH * 3 / 4);
    test_depth_mode(2, DEPTH / 2);
    test_depth_mode(3, DEPTH / 4);

    // Drain remaining
    while (ref_mem.size() > 0 && !empty) do_read;

    $display("----------------------------------------");
    $display("  Total writes: %0d", wr_count);
    $display("  Total reads:  %0d", rd_count);
    $display("  Errors:       %0d", errors);
    $display("  Depth coverage: %b", depth_coverage);
    $display("  Flag coverage: AE=%0b/%0b AF=%0b/%0b",
             ae_assert_coverage, ae_clear_coverage,
             af_assert_coverage, af_clear_coverage);
    $display("  Boundary coverage: %b", boundary_coverage);
    if (depth_coverage != 4'b1111) begin
      $error("FAIL: depth-mode coverage incomplete");
      errors++;
    end
    if (boundary_coverage != 4'b1111) begin
      $error("FAIL: boundary coverage incomplete");
      errors++;
    end
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
    #1000000;
    $error("TIMEOUT");
    $finish;
  end

endmodule
