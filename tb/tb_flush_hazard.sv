`timescale 1ns/1ps
// Regression for the flush-resume CDC hole: read attempts issued immediately
// after flush_busy deasserts must be blocked until the write pointer resyncs.
module tb_flush_hazard;
  localparam int DW = 8, DEPTH = 16, ADDR_W = 4;

  logic wr_clk = 0, rd_clk = 0, cfg_clk = 0;
  logic wr_rst_n = 0, rd_rst_n = 0, cfg_rst_n = 0;
  logic wr_en = 0, rd_en = 0, cfg_we = 0, cfg_re = 0;
  logic [DW-1:0] wr_data = 0, rd_data;
  logic full, empty, irq, almost_empty, almost_full;
  logic [3:0] cfg_addr = 0;
  logic [ADDR_W:0] cfg_wdata = 0, cfg_rdata;

  async_fifo #(.DW(DW), .DEPTH(DEPTH)) dut (
    .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .wr_en(wr_en), .wr_data(wr_data),
    .full(full), .rd_clk(rd_clk), .rd_rst_n(rd_rst_n), .rd_en(rd_en),
    .rd_data(rd_data), .empty(empty), .cfg_clk(cfg_clk), .cfg_rst_n(cfg_rst_n),
    .cfg_we(cfg_we), .cfg_re(cfg_re), .cfg_addr(cfg_addr),
    .cfg_wdata(cfg_wdata), .cfg_rdata(cfg_rdata), .irq(irq),
    .almost_empty(almost_empty), .almost_full(almost_full),
    .wr_ptr_gray_sync(), .rd_ptr_gray_sync()
  );

  always #100 wr_clk  = ~wr_clk;  // 5 MHz  (slow write side)
  always #10  rd_clk  = ~rd_clk;  // 50 MHz (fast read side)
  always #1   cfg_clk = ~cfg_clk; // 500 MHz (fast cfg side)

  int errors = 0;

  initial begin
    repeat (4) @(posedge wr_clk);
    wr_rst_n = 1; rd_rst_n = 1; cfg_rst_n = 1;
    repeat (4) @(posedge wr_clk);

    for (int i = 0; i < 6; i++) begin
      @(negedge wr_clk); wr_en = 1; wr_data = i;
      @(posedge wr_clk); #1 wr_en = 0;
    end
    repeat (6) @(posedge rd_clk);
    if (empty) begin $error("FAIL: FIFO empty before flush"); errors++; end

    @(negedge cfg_clk); cfg_addr = 8; cfg_wdata = 1; cfg_we = 1;
    @(negedge cfg_clk); cfg_we = 0;
    cfg_re = 1;
    #1;
    while (cfg_rdata[0]) begin @(negedge cfg_clk); #1; end
    cfg_re = 0;

    // The window: reads must be blocked and empty forced until resync.
    if (!empty) begin $error("FAIL: empty not forced after flush"); errors++; end
    repeat (3) begin
      @(negedge rd_clk); rd_en = 1;
      @(posedge rd_clk); #1 rd_en = 0;
    end
    repeat (8) @(posedge rd_clk);
    repeat (8) @(posedge wr_clk);
    if (dut.rd_ptr_bin !== 0 || dut.wr_ptr_bin !== 0 || !empty || full) begin
      $error("FAIL: flush left pointers desynced (wr=%0d rd=%0d empty=%b full=%b)",
             dut.wr_ptr_bin, dut.rd_ptr_bin, empty, full);
      errors++;
    end

    // Post-flush traffic must work and be verifiable.
    @(negedge wr_clk); wr_en = 1; wr_data = 8'hA5;
    @(posedge wr_clk); #1 wr_en = 0;
    repeat (4) @(posedge wr_clk);
    if (full) begin $error("FAIL: full after single post-flush write"); errors++; end
    @(negedge rd_clk); rd_en = 1;
    @(posedge rd_clk); #1 rd_en = 0;
    if (rd_data !== 8'hA5) begin $error("FAIL: post-flush data %0h", rd_data); errors++; end

    if (errors == 0) $display("*** FLUSH HAZARD TEST PASSED ***");
    else             $display("*** FLUSH HAZARD TEST FAILED (%0d errors) ***", errors);
    $finish;
  end

  initial begin
    #1000000;
    $error("TIMEOUT");
    $finish;
  end
endmodule