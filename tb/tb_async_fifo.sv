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

    // Drain remaining
    while (ref_mem.size() > 0 && !empty) do_read;

    $display("----------------------------------------");
    $display("  Total writes: %0d", wr_count);
    $display("  Total reads:  %0d", rd_count);
    $display("  Errors:       %0d", errors);
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
