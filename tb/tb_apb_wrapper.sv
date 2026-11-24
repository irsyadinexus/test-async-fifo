// -----------------------------------------------------------------------------
// tb_apb_wrapper.sv
// Self-checking testbench for fifo_apb_wrapper (single-clock APB slave).
//
// Test sequence:
//   a) Reset values of the configuration registers (0 = almost-empty,
//      1 = almost-full) read through the APB register window
//   b) Register write/readback (register 1)
//   c) Reserved configuration offset 9 reads 0 and ignores writes
//   d) Push 0xA1..0xA5 through the data window, pop them back in order
//   e) Push until full, observe PREADY wait states, abort, pop to free space,
//      then retry the push
//   f) Pop until empty, observe PREADY wait states, abort, push one word and
//      confirm the retried pop returns it
//   g) IRQ assertion through the register-3 mask and the almost-full threshold
//
// The APB master drives the bus with non-blocking assignments on posedge pclk
// and samples PREADY/PRDATA in the active region of the completion edge, which
// is race-free against the DUT's registered logic.
//
// A push while full / pop while empty stalls PREADY indefinitely (single APB
// master: nothing else can free space). The wait-state tests therefore abort
// the stalled access by deasserting PSEL at test level -- a real master must
// poll IRQ status (register 4) instead.
//
// Usage (Icarus Verilog):
//   iverilog -g2012 -o sim/tb_apb_wrapper.vvp -I rtl \
//     rtl/async_fifo.sv rtl/fifo_apb_cfg.sv rtl/fifo_apb_wrapper.sv \
//     tb/tb_apb_wrapper.sv
//   vvp sim/tb_apb_wrapper.vvp
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_apb_wrapper;

  // --- Parameters ---
  localparam int DW     = 8;
  localparam int DEPTH  = 16;
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int PTR_W  = ADDR_W + 1;

  localparam logic [31:0] REG_WIN  = 32'h0000_0000;
  localparam logic [31:0] DATA_WIN = 32'h0000_0100;

  // --- DUT signals ---
  logic        pclk, presetn;
  logic        psel, penable, pwrite;
  logic [31:0] paddr, pwdata, prdata;
  logic        pready, pslverr;
  logic        irq, almost_empty, almost_full;
  logic [ADDR_W:0] wr_ptr_gray_sync, rd_ptr_gray_sync;

  // --- DUT ---
  fifo_apb_wrapper #(
    .DW    (DW),
    .DEPTH (DEPTH)
  ) dut (
    .pclk             (pclk),
    .presetn          (presetn),
    .psel             (psel),
    .penable          (penable),
    .pwrite           (pwrite),
    .paddr            (paddr),
    .pwdata           (pwdata),
    .prdata           (prdata),
    .pready           (pready),
    .pslverr          (pslverr),
    .irq              (irq),
    .almost_empty     (almost_empty),
    .almost_full      (almost_full),
    .wr_ptr_gray_sync (wr_ptr_gray_sync),
    .rd_ptr_gray_sync (rd_ptr_gray_sync)
  );

  // 100 MHz APB clock
  initial pclk = 0;
  always #5 pclk = ~pclk;

  // -----------------------------------------------------------------------
  // Scoreboard
  // -----------------------------------------------------------------------
  logic [DW-1:0] ref_mem [$];
  int            errors = 0;
  int            push_count = 0;
  int            pop_count  = 0;

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
      presetn = 0;
      psel    = 0;
      penable = 0;
      pwrite  = 0;
      paddr   = 0;
      pwdata  = 0;
      ref_mem.delete();
      repeat (3) @(posedge pclk);
      presetn = 1;
      repeat (2) @(posedge pclk);
    end
  endtask

  // -----------------------------------------------------------------------
  // APB master BFM
  // -----------------------------------------------------------------------
  task automatic apb_write(input logic [31:0] addr, input logic [31:0] data);
    begin
      @(posedge pclk);
      psel <= 1; penable <= 0; pwrite <= 1; paddr <= addr; pwdata <= data;
      @(posedge pclk);
      penable <= 1;
      @(posedge pclk);
      while (!pready) @(posedge pclk);
      psel <= 0; penable <= 0; pwrite <= 0;
    end
  endtask

  task automatic apb_read(input logic [31:0] addr, output logic [31:0] data);
    begin
      @(posedge pclk);
      psel <= 1; penable <= 0; pwrite <= 0; paddr <= addr;
      @(posedge pclk);
      penable <= 1;
      @(posedge pclk);
      while (!pready) @(posedge pclk);
      data = prdata;  // valid during the completing access phase
      psel <= 0; penable <= 0;
    end
  endtask

  // -----------------------------------------------------------------------
  // Stalled-access probes: assert the access, count wait states, abort.
  // A compliant master never aborts; this only exercises the wait path.
  // -----------------------------------------------------------------------
  task automatic apb_probe_stall(input logic [31:0] addr, input bit wr,
                                 input logic [31:0] data, input int min_stall,
                                 output int stalls);
    begin
      stalls = 0;
      @(posedge pclk);
      psel <= 1; penable <= 0; pwrite <= wr; paddr <= addr; pwdata <= data;
      @(posedge pclk);
      penable <= 1;
      @(posedge pclk);
      while (!pready && stalls < min_stall + 4) begin
        stalls++;
        @(posedge pclk);
      end
      psel <= 0; penable <= 0; pwrite <= 0;
      repeat (2) @(posedge pclk);
      if (stalls < min_stall)
        fail($sformatf("expected >= %0d wait states on 0x%03h, saw %0d",
                       min_stall, addr, stalls));
    end
  endtask

  // Push / pop helpers on the data window, checked against ref_mem.
  task automatic apb_push(input logic [7:0] data);
    begin
      apb_write(DATA_WIN, {24'd0, data});
      ref_mem.push_back(data);
      push_count++;
    end
  endtask

  task automatic apb_pop(output logic [7:0] data);
    logic [31:0] r;
    begin
      apb_read(DATA_WIN, r);
      if (ref_mem.size() == 0) begin
        fail("pop on empty reference model");
        data = 8'hxx;
      end else begin
        data = ref_mem.pop_front();
        if (r !== {24'd0, data}) begin
          $error("FAIL: pop got 0x%08h expected 0x%08h", r, {24'd0, data});
          errors++;
        end
        pop_count++;
      end
    end
  endtask

  // -----------------------------------------------------------------------
  // Tests
  // -----------------------------------------------------------------------
  task automatic test_reset_values;
    logic [31:0] d;
    begin
      $display("=== (a) configuration reset values ===");
      do_reset;
      apb_read(REG_WIN + 0, d);              // almost-empty threshold
      expect32("reg0 almost-empty default", d, 32'((DEPTH + 4) / 5));
      apb_read(REG_WIN + 4, d);              // almost-full threshold
      expect32("reg1 almost-full default", d, 32'((4 * DEPTH + 4) / 5));
      apb_read(REG_WIN + 8, d);              // active depth
      expect32("reg2 active depth default", d, 32'(DEPTH));
      apb_read(REG_WIN + 24, d);             // flush status
      expect32("reg8 flush status reset", d, 32'd0);
    end
  endtask

  task automatic test_register_rw;
    logic [31:0] d;
    begin
      $display("=== (b) register write/readback ===");
      do_reset;
      apb_write(REG_WIN + 4, 32'd5);
      apb_read(REG_WIN + 4, d);
      expect32("reg1 readback", d, 32'd5);
      apb_write(REG_WIN + 4, 32'((4 * DEPTH + 4) / 5));  // restore default
      apb_read(REG_WIN + 4, d);
      expect32("reg1 restored", d, 32'((4 * DEPTH + 4) / 5));

      // IRQ mask readback through the same window
      apb_write(REG_WIN + 12, 32'hF);
      apb_read(REG_WIN + 12, d);
      expect32("reg3 mask readback", d, 32'hF);
    end
  endtask

  task automatic test_reserved_offset;
    logic [31:0] d;
    begin
      $display("=== (c) reserved configuration offset 9 ===");
      do_reset;
      apb_write(REG_WIN + (9 * 4), 32'hDEAD_BEEF);
      apb_read(REG_WIN + (9 * 4), d);
      expect32("reg9 reads 0", d, 32'd0);
      apb_read(REG_WIN + 4, d);
      expect32("reg1 untouched by reg9 write", d, 32'((4 * DEPTH + 4) / 5));
      apb_read(REG_WIN + 24, d);  // occupancy, FIFO must still be empty
      expect32("occupancy still 0", d, 32'd0);
    end
  endtask

  task automatic test_data_roundtrip;
    logic [7:0] d;
    logic [31:0] r;
    int i;
    begin
      $display("=== (d) data-window round trip ===");
      do_reset;
      for (i = 0; i < 5; i++) apb_push(8'hA1 + i[7:0]);
      for (i = 0; i < 5; i++) begin
        apb_pop(d);
        if (d !== 8'hA1 + i[7:0])
          $error("FAIL: round-trip order at %0d: got 0x%02h", i, d);
      end
      apb_read(REG_WIN + 24, r);
      expect32("occupancy after drain", r, 32'd0);
    end
  endtask

  task automatic test_push_full_stall;
    logic [31:0] r;
    logic [7:0]  d;
    int i, stalls;
    begin
      $display("=== (e) push-while-full wait states ===");
      do_reset;
      for (i = 0; i < DEPTH; i++) apb_push(8'h10 + i[7:0]);
      apb_read(REG_WIN + 16, r);             // irq status
      if (!r[0]) fail("full status not set after DEPTH pushes");

      // Extra push cannot complete: PREADY must stretch.
      apb_probe_stall(DATA_WIN, 1'b1, 32'h0000_00EE, 3, stalls);
      if (stalls > 0) $display("  push stall observed: %0d wait states", stalls);

      // Free one slot, then the same push completes normally.
      apb_pop(d);
      if (d !== 8'h10) fail("first pop data mismatch");
      apb_push(8'hEE);
      apb_read(REG_WIN + 24, r);
      expect32("occupancy after stall+retry", r, 32'(DEPTH));

      for (i = 0; i < DEPTH; i++) begin
        logic [7:0] exp;
        apb_pop(d);
        // 0x11..0x1F stay in order, then the retried 0xEE push
        exp = (i < DEPTH - 1) ? (8'h11 + i[7:0]) : 8'hEE;
        if (d !== exp) begin
          $error("FAIL: post-stall drain at %0d: got 0x%02h expected 0x%02h",
                 i, d, exp);
          errors++;
        end
      end
      apb_read(REG_WIN + 24, r);
      expect32("occupancy drained", r, 32'd0);
    end
  endtask

  task automatic test_pop_empty_stall;
    logic [31:0] r;
    logic [7:0]  d;
    int stalls;
    begin
      $display("=== (f) pop-while-empty wait states ===");
      do_reset;
      apb_read(REG_WIN + 16, r);
      if (!r[1]) fail("empty status not set after reset");

      apb_probe_stall(DATA_WIN, 1'b0, 32'd0, 3, stalls);
      if (stalls > 0) $display("  pop stall observed: %0d wait states", stalls);

      apb_push(8'h5A);
      apb_pop(d);
      if (d !== 8'h5A) fail("retried pop data mismatch");
      apb_read(REG_WIN + 24, r);
      expect32("occupancy empty after retry", r, 32'd0);
    end
  endtask

  task automatic test_irq;
    logic [31:0] r;
    logic [7:0]  d;
    int i;
    begin
      $display("=== (g) IRQ through mask and almost-full ===");
      do_reset;
      apb_write(REG_WIN + 12, 32'h4);        // mask almost-full only
      for (i = 0; i < (4 * DEPTH + 4) / 5; i++) apb_push(8'h40 + i[7:0]);
      repeat (6) @(posedge pclk);
      if (!almost_full) fail("almost_full not asserted at threshold");
      if (!irq)         fail("irq not asserted for masked almost-full");
      apb_read(REG_WIN + 16, r);
      if (!r[2]) fail("almost-full status bit not set");

      apb_write(REG_WIN + 12, 32'h0);        // mask off
      repeat (4) @(posedge pclk);
      if (irq) fail("irq still asserted after masking");

      for (i = 0; i < (4 * DEPTH + 4) / 5; i++) apb_pop(d);
      repeat (6) @(posedge pclk);
      if (almost_full) fail("almost_full still asserted after drain");
    end
  endtask

  // -----------------------------------------------------------------------
  // Main
  // -----------------------------------------------------------------------
  initial begin
    psel    = 0;
    penable = 0;
    pwrite  = 0;
    paddr   = 0;
    pwdata  = 0;

    $display("========================================");
    $display("  fifo_apb_wrapper testbench (DW=%0d, DEPTH=%0d)", DW, DEPTH);
    $display("========================================");

    test_reset_values;
    test_register_rw;
    test_reserved_offset;
    test_data_roundtrip;
    test_push_full_stall;
    test_pop_empty_stall;
    test_irq;

    $display("----------------------------------------");
    $display("  Pushes: %0d", push_count);
    $display("  Pops:   %0d", pop_count);
    $display("  Errors: %0d", errors);
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
    #500000;
    $error("TIMEOUT");
    $finish;
  end

endmodule
