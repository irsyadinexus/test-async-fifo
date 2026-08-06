// -----------------------------------------------------------------------------
// async_fifo_if.sv
// Interface file for the async FIFO (optional — for use with UVM or
// module-based testbenches). Not strictly required for synthesis.
// -----------------------------------------------------------------------------

`default_nettype none

interface async_fifo_if #(parameter int DW = 8, parameter int DEPTH = 16) ();

  logic                  wr_clk;
  logic                  wr_rst_n;
  logic                  wr_en;
  logic  [DW-1:0]        wr_data;
  logic                  full;

  logic                  rd_clk;
  logic                  rd_rst_n;
  logic                  rd_en;
  logic  [DW-1:0]        rd_data;
  logic                  empty;
  logic                  cfg_clk, cfg_rst_n, cfg_we;
  logic [1:0]            cfg_addr;
  logic [$clog2(DEPTH):0] cfg_wdata;
  logic                  almost_empty, almost_full;

  logic [$clog2(DEPTH):0] wr_ptr_gray_sync;
  logic [$clog2(DEPTH):0] rd_ptr_gray_sync;

  // Convenience clocking blocks
  clocking cb_wr @(posedge wr_clk);
    input   full;
    output  wr_en, wr_data;
  endclocking

  clocking cb_rd @(posedge rd_clk);
    input   empty, rd_data;
    output  rd_en;
  endclocking

endinterface

`default_nettype wire
