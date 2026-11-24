// -----------------------------------------------------------------------------
// tb_two_fifo.sv
// Controller-driven two-FIFO chain simulation.
//
// One behavioral controller fills FIFO1 with random data, moves it into FIFO2,
// reads FIFO2 back and compares; then fills FIFO2 with ascending data, moves it
// back into FIFO1, reads FIFO1 back and compares. Every FIFO port runs on its
// own clock frequency and phase, so both DUTs' internal Gray-code CDC is
// exercised. The controller waits 100 of its own clock cycles between a
// completed burst of writes and the following burst of reads (and vice versa);
// accesses inside a burst run back-to-back on the target port's clock.
//
// Usage (Icarus Verilog), from the repository root:
//   iverilog -g2012 -o sim/tb_two.vvp -I rtl rtl/async_fifo.sv tb/tb_two_fifo.sv
//   vvp sim/tb_two.vvp
//   gtkwave sim/tb_two_fifo.vcd
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_two_fifo;

  // --- Parameters ---
  localparam int DW     = 8;
  localparam int DEPTH  = 64;
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int PTR_W  = ADDR_W + 1;

  // --- Controller clock and four independent FIFO port clocks ---
  // Each is a distinct non-harmonic frequency with a distinct phase offset.
  logic ctl_clk = 0, f1w = 0, f1r = 0, f2w = 0, f2r = 0;
  initial forever #5       ctl_clk = ~ctl_clk;           //  10.00  ns, 100.0 MHz, phase 0
  initial begin #1.3;  forever #38.4615 f1w = ~f1w; end  //  76.92  ns,  13.0 MHz, phase 1.3 ns
  initial begin #3.1;  forever #55.5556 f1r = ~f1r; end  // 111.11  ns,   9.0 MHz, phase 3.1 ns
  initial begin #7.3;  forever #71.4286 f2w = ~f2w; end  // 142.86  ns,   7.0 MHz, phase 7.3 ns
  initial begin #4.5;  forever #45.4545 f2r = ~f2r; end  //  90.91  ns,  11.0 MHz, phase 4.5 ns

  // --- Resets (separate async reset per port domain) ---
  logic rst1w = 0, rst1r = 0, rst2w = 0, rst2r = 0;

  // --- FIFO1 port signals ---
  logic            f1_wr_en = 0, f1_rd_en = 0;
  logic [DW-1:0]   f1_wr_data = 0, f1_rd_data;
  logic            f1_full, f1_empty;

  // --- FIFO2 port signals ---
  logic            f2_wr_en = 0, f2_rd_en = 0;
  logic [DW-1:0]   f2_wr_data = 0, f2_rd_data;
  logic            f2_full, f2_empty;

  // --- Unused config/status signals ---
  logic [3:0]      cfg_addr  = 4'd0;
  logic [ADDR_W:0] cfg_wdata = '0;
  logic [ADDR_W:0] cfg_rdata1, cfg_rdata2;

  // --- DUTs ---
  async_fifo #(
    .DW(DW),
    .DEPTH(DEPTH)
  ) dut1 (
    .wr_clk           (f1w),
    .wr_rst_n         (rst1w),
    .wr_en            (f1_wr_en),
    .wr_data          (f1_wr_data),
    .full             (f1_full),
    .rd_clk           (f1r),
    .rd_rst_n         (rst1r),
    .rd_en            (f1_rd_en),
    .rd_data          (f1_rd_data),
    .empty            (f1_empty),
    .cfg_clk          (f1w),
    .cfg_rst_n        (rst1w),
    .cfg_we           (1'b0),
    .cfg_re           (1'b0),
    .cfg_addr         (cfg_addr),
    .cfg_wdata        (cfg_wdata),
    .cfg_rdata        (cfg_rdata1),
    .irq              (),
    .almost_empty     (),
    .almost_full      (),
    .wr_ptr_gray_sync (),
    .rd_ptr_gray_sync ()
  );

  async_fifo #(
    .DW(DW),
    .DEPTH(DEPTH)
  ) dut2 (
    .wr_clk           (f2w),
    .wr_rst_n         (rst2w),
    .wr_en            (f2_wr_en),
    .wr_data          (f2_wr_data),
    .full             (f2_full),
    .rd_clk           (f2r),
    .rd_rst_n         (rst2r),
    .rd_en            (f2_rd_en),
    .rd_data          (f2_rd_data),
    .empty            (f2_empty),
    .cfg_clk          (f2w),
    .cfg_rst_n        (rst2w),
    .cfg_we           (1'b0),
    .cfg_re           (1'b0),
    .cfg_addr         (cfg_addr),
    .cfg_wdata        (cfg_wdata),
    .cfg_rdata        (cfg_rdata2),
    .irq              (),
    .almost_empty     (),
    .almost_full      (),
    .wr_ptr_gray_sync (),
    .rd_ptr_gray_sync ()
  );

  // -----------------------------------------------------------------------
  // Reference model: one expected-data queue per FIFO
  // -----------------------------------------------------------------------
  logic [DW-1:0] exp1 [$];
  logic [DW-1:0] exp2 [$];
  logic [DW-1:0] move_q  [$]; // move buffer: drained FIFO -> refilled FIFO
  int errors     = 0;
  int wr1_count  = 0;
  int rd1_count  = 0;
  int wr2_count  = 0;
  int rd2_count  = 0;

  // -----------------------------------------------------------------------
  // Reset task: assert all four resets, hold across each port clock, release
  // them together.
  // -----------------------------------------------------------------------
  task automatic do_reset;
    begin
      rst1w = 0; rst1r = 0; rst2w = 0; rst2r = 0;
      f1_wr_en = 0; f1_rd_en = 0; f1_wr_data = 0;
      f2_wr_en = 0; f2_rd_en = 0; f2_wr_data = 0;
      exp1.delete();
      exp2.delete();
      move_q.delete();
      repeat (4) @(posedge f1w);
      repeat (4) @(posedge f1r);
      repeat (4) @(posedge f2w);
      repeat (4) @(posedge f2r);
      rst1w = 1; rst1r = 1; rst2w = 1; rst2r = 1;
      @(posedge f1w);
      @(posedge f1r);
      @(posedge f2w);
      @(posedge f2r);
    end
  endtask

  // -----------------------------------------------------------------------
  // 100 controller-clock-cycle gap between a completed burst of writes and
  // the following burst of reads (or vice versa) — not between the individual
  // accesses inside a burst.
  // -----------------------------------------------------------------------
  task automatic gap;
    repeat (100) @(posedge ctl_clk);
  endtask

  // -----------------------------------------------------------------------
  // Port access tasks (negedge drive, posedge accept, #1 deassert)
  // -----------------------------------------------------------------------
  task automatic f1_write(input [DW-1:0] d);
    begin
      while (f1_full) @(posedge f1w);
      @(negedge f1w); f1_wr_en = 1; f1_wr_data = d;
      @(posedge f1w); #1 f1_wr_en = 0;
      wr1_count++;
    end
  endtask

  task automatic f1_read(output [DW-1:0] d);
    begin
      while (f1_empty) @(posedge f1r);
      @(negedge f1r); f1_rd_en = 1;
      @(posedge f1r); #1 f1_rd_en = 0;
      d = f1_rd_data;
      rd1_count++;
    end
  endtask

  task automatic f2_write(input [DW-1:0] d);
    begin
      while (f2_full) @(posedge f2w);
      @(negedge f2w); f2_wr_en = 1; f2_wr_data = d;
      @(posedge f2w); #1 f2_wr_en = 0;
      wr2_count++;
    end
  endtask

  task automatic f2_read(output [DW-1:0] d);
    begin
      while (f2_empty) @(posedge f2r);
      @(negedge f2r); f2_rd_en = 1;
      @(posedge f2r); #1 f2_rd_en = 0;
      d = f2_rd_data;
      rd2_count++;
    end
  endtask

  // -----------------------------------------------------------------------
  // Main stimulus
  // -----------------------------------------------------------------------
  initial begin
    logic [DW-1:0] d, e;
    int i;

    $dumpfile("sim/tb_two_fifo.vcd");
    $dumpvars(0, tb_two_fifo);

    $display("========================================");
    $display("  Two-FIFO Chain Simulation");
    $display("  DW=%0d  DEPTH=%0d  ADDR_W=%0d", DW, DEPTH, ADDR_W);
    $display("  Clocks: ctl 10 ns (100 MHz) ph 0 | f1w 76.92 ns (13 MHz) ph 1.3");
    $display("          f1r 111.11 ns (9 MHz) ph 3.1 | f2w 142.86 ns (7 MHz) ph 7.3");
    $display("          f2r 90.91 ns (11 MHz) ph 4.5");
    $display("  Controller waits 100 ctl_clk cycles between write and read bursts");
    $display("========================================");

    do_reset;

    // --- Phase 1: fill FIFO1 with random data -----------------------------
    $display("=== Phase 1: fill FIFO1 with random data ===");
    repeat (DEPTH) begin
      d = DW'($urandom);
      f1_write(d);
      exp1.push_back(d);
    end
    gap; // completed write burst -> read burst
    $display("  Phase 1: filled FIFO1 with %0d random words, back-to-back", DEPTH);

    // --- Phase 2: move FIFO1 -> FIFO2 ------------------------------------
    // Per-word compare proves FIFO1's f1w->f1r Gray CDC.
    $display("=== Phase 2: move FIFO1 -> FIFO2 ===");
    repeat (DEPTH) begin
      f1_read(d);
      if (exp1.size() == 0) begin
        $error("MODEL UNDERFLOW: DUT read with empty model");
        errors++;
      end else begin
        e = exp1.pop_front();
        if (d !== e) begin
          $error("MOVE1 MISMATCH: got %0d, expected %0d", d, e);
          errors++;
        end
        move_q.push_back(d);
      end
    end
    gap; // completed read burst -> write burst
    while (move_q.size() > 0) begin
      d = move_q.pop_front();
      f2_write(d);
      exp2.push_back(d);
    end
    gap; // completed write burst -> read burst
    $display("  Phase 2: moved %0d words (f1 reads=%0d, f2 writes=%0d)",
             DEPTH, rd1_count, wr2_count);

    // --- Phase 3: read FIFO2 back ----------------------------------------
    // Per-word compare proves FIFO2's f2w->f2r Gray CDC.
    $display("=== Phase 3: read FIFO2 back ===");
    repeat (DEPTH) begin
      f2_read(d);
      if (exp2.size() == 0) begin
        $error("MODEL UNDERFLOW: DUT read with empty model");
        errors++;
      end else begin
        e = exp2.pop_front();
        if (d !== e) begin
          $error("READBACK2 MISMATCH: got %0d, expected %0d", d, e);
          errors++;
        end
      end
    end
    repeat (8) @(posedge f2r);
    if (!f2_empty) begin
      $error("FAIL: FIFO2 not empty after readback");
      errors++;
    end
    $display("  Phase 3: read back %0d words, FIFO2 empty=%b", rd2_count, f2_empty);
    gap; // completed read burst -> write burst

    // --- Phase 4: fill FIFO2 with ascending data -------------------------
    $display("=== Phase 4: fill FIFO2 with ascending data ===");
    for (i = 0; i < DEPTH; i++) begin
      d = DW'(i);
      f2_write(d);
      exp2.push_back(d);
    end
    gap; // completed write burst -> read burst
    $display("  Phase 4: filled FIFO2 with %0d ascending words, back-to-back", DEPTH);

    // --- Phase 5: move FIFO2 -> FIFO1 ------------------------------------
    $display("=== Phase 5: move FIFO2 -> FIFO1 ===");
    repeat (DEPTH) begin
      f2_read(d);
      if (exp2.size() == 0) begin
        $error("MODEL UNDERFLOW: DUT read with empty model");
        errors++;
      end else begin
        e = exp2.pop_front();
        if (d !== e) begin
          $error("MOVE2 MISMATCH: got %0d, expected %0d", d, e);
          errors++;
        end
        move_q.push_back(d);
      end
    end
    gap; // completed read burst -> write burst
    while (move_q.size() > 0) begin
      d = move_q.pop_front();
      f1_write(d);
      exp1.push_back(d);
    end
    gap; // completed write burst -> read burst
    $display("  Phase 5: moved %0d words (f2 reads=%0d, f1 writes=%0d)",
             DEPTH, rd2_count, wr1_count);

    // --- Phase 6: read FIFO1 back ----------------------------------------
    $display("=== Phase 6: read FIFO1 back ===");
    repeat (DEPTH) begin
      f1_read(d);
      if (exp1.size() == 0) begin
        $error("MODEL UNDERFLOW: DUT read with empty model");
        errors++;
      end else begin
        e = exp1.pop_front();
        if (d !== e) begin
          $error("READBACK1 MISMATCH: got %0d, expected %0d", d, e);
          errors++;
        end
      end
    end
    repeat (8) @(posedge f1r);
    if (!f1_empty) begin
      $error("FAIL: FIFO1 not empty after readback");
      errors++;
    end
    $display("  Phase 6: read back %0d words, FIFO1 empty=%b", rd1_count, f1_empty);

    // --- Phase 7: final integrity ----------------------------------------
    $display("=== Phase 7: final integrity ===");
    repeat (2) @(posedge f1w);
    repeat (2) @(posedge f2w);
    if (dut1.empty !== 1'b1 || dut2.empty !== 1'b1) begin
      $error("FAIL: FIFO not empty at end (f1=%b f2=%b)", dut1.empty, dut2.empty);
      errors++;
    end
    if (dut1.wr_ptr_bin !== {PTR_W{1'b0}} || dut1.rd_ptr_bin !== {PTR_W{1'b0}} ||
        dut2.wr_ptr_bin !== {PTR_W{1'b0}} || dut2.rd_ptr_bin !== {PTR_W{1'b0}}) begin
      $error("FAIL: pointers not balanced (f1 wr=%0d rd=%0d, f2 wr=%0d rd=%0d)",
             dut1.wr_ptr_bin, dut1.rd_ptr_bin, dut2.wr_ptr_bin, dut2.rd_ptr_bin);
      errors++;
    end

    $display("----------------------------------------");
    $display("  Total FIFO1 writes/reads: %0d/%0d", wr1_count, rd1_count);
    $display("  Total FIFO2 writes/reads: %0d/%0d", wr2_count, rd2_count);
    $display("  Errors: %0d", errors);
    $display("========================================");
    if (errors == 0)
      $display("  *** TWO-FIFO CHAIN TEST PASSED ***");
    else
      $display("  *** TWO-FIFO CHAIN TEST FAILED (%0d errors) ***", errors);
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