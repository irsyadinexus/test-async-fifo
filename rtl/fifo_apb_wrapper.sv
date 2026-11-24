// -----------------------------------------------------------------------------
// fifo_apb_wrapper.sv
// APB slave wrapper for async_fifo
// - One APB slave, two address windows selected by paddr[8]
//   * paddr[8]=0: configuration register window, word offsets 0..15
//     (byte addresses 0x000..0x03C), bridged by fifo_apb_cfg
//   * paddr[8]=1: data window (e.g. 0x100); write = push, read = pop
// - Whole core runs on pclk: wr_clk = rd_clk = cfg_clk = pclk
// - Bus data is 32 bits: push takes pwdata[DW-1:0], pop returns
//   zero-extended data
// - Pop costs one wait state because the core read data is registered
// - A push while `full`, or a pop while `empty`, holds PREADY low for as long
//   as the condition lasts. APB has a single master, so nothing else can free
//   space: software must poll IRQ status (register 4, bit 0 full / bit 1 empty)
//   before pushing into a possibly-full FIFO or popping an empty one.
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns/1ps

module fifo_apb_wrapper #(
    parameter int DW     = 8,
    parameter int DEPTH  = 16,
    parameter int ADDR_W = $clog2(DEPTH)
) (
    input  wire           pclk,
    input  wire           presetn,   // active-low, async assert

    // APB slave
    input  wire           psel,
    input  wire           penable,
    input  wire           pwrite,
    input  wire [31:0]    paddr,
    input  wire [31:0]    pwdata,
    output logic [31:0]   prdata,
    output wire           pready,
    output wire           pslverr,

    // Status
    output wire           irq,
    output wire           almost_empty,
    output wire           almost_full,
    output wire [ADDR_W:0] wr_ptr_gray_sync,
    output wire [ADDR_W:0] rd_ptr_gray_sync
);

  localparam int PTR_W = ADDR_W + 1;

  // -------------------------------------------------------------------------
  // Window decode
  // -------------------------------------------------------------------------
  wire sel_reg  = psel && !paddr[8];
  wire sel_data = psel &&  paddr[8];

  // -------------------------------------------------------------------------
  // Register window: combinational APB -> cfg bridge
  // -------------------------------------------------------------------------
  logic             cfg_we, cfg_re;
  logic [3:0]       cfg_addr;
  logic [PTR_W-1:0] cfg_wdata, cfg_rdata;
  logic [31:0]      cfg_prdata;
  wire              cfg_pready;

  fifo_apb_cfg #(
    .PTR_W (PTR_W)
  ) u_cfg (
    .psel      (sel_reg),
    .penable   (penable),
    .pwrite    (pwrite),
    .paddr     (paddr[5:2]),
    .pwdata    (pwdata),
    .prdata    (cfg_prdata),
    .pready    (cfg_pready),
    .cfg_we    (cfg_we),
    .cfg_re    (cfg_re),
    .cfg_addr  (cfg_addr),
    .cfg_wdata (cfg_wdata),
    .cfg_rdata (cfg_rdata)
  );

  // -------------------------------------------------------------------------
  // Data window: push is a single access-phase cycle, pop needs one wait state
  // -------------------------------------------------------------------------
  logic             full, empty;
  logic [DW-1:0]    rd_data;
  wire              rd_en;
  logic             pop_wait;   // popped word present in rd_data

  assign rd_en = sel_data && penable && !pwrite && !pop_wait && !empty;

  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn)        pop_wait <= 1'b0;
    else if (rd_en)      pop_wait <= 1'b1;
    else if (pop_wait)   pop_wait <= sel_data && penable && !pwrite;
  end

  wire push = sel_data && penable && pwrite && !full;

  // PREADY: register window never waits; data window waits while full (push)
  // or until the popped word is available (pop).
  assign pready = paddr[8] ? (pwrite ? !full : pop_wait) : cfg_pready;

  always_comb begin
    if (!paddr[8])       prdata = cfg_prdata;
    else if (pop_wait)   prdata = 32'(rd_data);
    else                 prdata = 32'd0;
  end

  // No error responses: every unsatisfiable access stalls instead.
  assign pslverr = 1'b0;

  // -------------------------------------------------------------------------
  // FIFO core: single clock domain
  // -------------------------------------------------------------------------
  async_fifo #(
    .DW    (DW),
    .DEPTH (DEPTH)
  ) u_fifo (
    .wr_clk           (pclk),
    .wr_rst_n         (presetn),
    .wr_en            (push),
    .wr_data          (pwdata[DW-1:0]),
    .full             (full),
    .rd_clk           (pclk),
    .rd_rst_n         (presetn),
    .rd_en            (rd_en),
    .rd_data          (rd_data),
    .empty            (empty),
    .cfg_clk          (pclk),
    .cfg_rst_n        (presetn),
    .cfg_we           (cfg_we),
    .cfg_re           (cfg_re),
    .cfg_addr         (cfg_addr),
    .cfg_wdata        (cfg_wdata),
    .cfg_rdata        (cfg_rdata),
    .irq              (irq),
    .almost_empty     (almost_empty),
    .almost_full      (almost_full),
    .wr_ptr_gray_sync (wr_ptr_gray_sync),
    .rd_ptr_gray_sync (rd_ptr_gray_sync)
  );

endmodule

`default_nettype wire
