// -----------------------------------------------------------------------------
// fifo_ahb_wrapper.sv
// AHB-Lite data-slave wrapper for async_fifo, with a separate APB config port
// - AHB-Lite slave: single data window, write = push, read = pop
// - APB slave: the FIFO configuration register window (registers 0..8) plus a
//   wrapper-local MODE register at word offset 9
// - MODE selects which side of the FIFO the AHB engine owns:
//     0: AHB pushes and pops (both FIFO raw ports driven by the AHB engine)
//     1: AHB pushes, raw read side exposed on rd_clk   (core_rd_clk = rd_clk)
//     2: AHB pops,   raw write side exposed on wr_clk  (core_wr_clk = wr_clk)
//     3: reserved, behaves as 0
// - Pops cost one wait state (registered core read data). A push while `full`
//   or a pop while `empty` stretches HREADYOUT until the condition clears; in
//   MODE 0 nothing else can free space, so software must poll IRQ status
//   (config register 4, bit 0 full / bit 1 empty) before such a transfer.
// - MODE is only changed while the affected data-domain reset is asserted:
//   assert wr_rst_n and/or rd_rst_n, write MODE through the APB port, release.
//   The clock muxes are plain combinational muxes with no live-switch
//   protection, so this quasi-static procedure is mandatory.
// - The AHB engine always uses `full`/`empty` from the FIFO side it owns,
//   which is the hclk domain by construction of the MODE mux.
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns/1ps

module fifo_ahb_wrapper #(
    parameter int DW     = 8,
    parameter int DEPTH  = 16,
    parameter int ADDR_W = $clog2(DEPTH)
) (
    // AHB-Lite data slave
    input  wire           hclk,
    input  wire           hresetn,
    input  wire           hsel,
    input  wire [31:0]    haddr,     // ignored: single data window
    input  wire [1:0]     htrans,    // only HTRANS[1] accepted (NONSEQ/SEQ)
    input  wire           hwrite,
    input  wire [2:0]     hsize,     // ignored: full-word transfers assumed
    input  wire [31:0]    hwdata,
    output logic [31:0]   hrdata,
    input  wire           hready,    // global HREADY from the interconnect
    output wire           hreadyout,
    output wire           hresp,     // tied 0 (OKAY); the slave stalls instead

    // APB configuration slave
    input  wire           cfg_clk,
    input  wire           cfg_presetn,
    input  wire           cfg_psel,
    input  wire           cfg_penable,
    input  wire           cfg_pwrite,
    input  wire [31:0]    cfg_paddr,
    input  wire [31:0]    cfg_pwdata,
    output logic [31:0]   cfg_prdata,
    output wire           cfg_pready,

    // FIFO core resets and the externally exposed raw side
    input  wire           wr_clk,
    input  wire           wr_rst_n,
    input  wire           rd_clk,
    input  wire           rd_rst_n,
    input  wire           ext_wr_en,
    input  wire [DW-1:0]  ext_wr_data,
    input  wire           ext_rd_en,
    output wire [DW-1:0]  ext_rd_data,

    // Status
    output wire           full,
    output wire           empty,
    output wire           almost_full,
    output wire           almost_empty,
    output wire           irq,
    output wire [ADDR_W:0] wr_ptr_gray_sync,
    output wire [ADDR_W:0] rd_ptr_gray_sync
);

  localparam int PTR_W = ADDR_W + 1;

  // -------------------------------------------------------------------------
  // APB configuration window + wrapper-local MODE register (offset 9)
  // -------------------------------------------------------------------------
  wire [3:0]       cfg_off = cfg_paddr[5:2];
  logic [1:0]      mode_q;

  logic             cfg_we, cfg_re;
  logic [3:0]       cfg_addr;
  logic [PTR_W-1:0] cfg_wdata, cfg_rdata;
  logic [31:0]      bridge_prdata;
  wire              bridge_pready;

  fifo_apb_cfg #(
    .PTR_W (PTR_W)
  ) u_cfg (
    .psel      (cfg_psel),
    .penable   (cfg_penable),
    .pwrite    (cfg_pwrite),
    .paddr     (cfg_off),
    .pwdata    (cfg_pwdata),
    .prdata    (bridge_prdata),
    .pready    (bridge_pready),
    .cfg_we    (cfg_we),
    .cfg_re    (cfg_re),
    .cfg_addr  (cfg_addr),
    .cfg_wdata (cfg_wdata),
    .cfg_rdata (cfg_rdata)
  );

  always_ff @(posedge cfg_clk or negedge cfg_presetn) begin
    if (!cfg_presetn)                    mode_q <= 2'd0;
    else if (cfg_we && cfg_addr == 4'd9) mode_q <= cfg_wdata[1:0];
  end

  // Offset 9 is wrapper-local; every other offset comes from the core.
  assign cfg_prdata = (cfg_psel && !cfg_pwrite && cfg_off == 4'd9)
                      ? 32'(mode_q) : bridge_prdata;
  assign cfg_pready = bridge_pready;

  // Reserved value 3 behaves as 0.
  function automatic logic [1:0] mode_decode(input logic [1:0] m);
    case (m)
      2'd1:    return 2'd1;
      2'd2:    return 2'd2;
      default: return 2'd0;
    endcase
  endfunction

  wire [1:0] mode_eff  = mode_decode(mode_q);

  // Which FIFO port the AHB engine owns: it pushes in MODE 0 and 1, and pops
  // in MODE 0 and 2. The other side is driven by the external raw pins.
  wire push_owned = (mode_eff != 2'd2);
  wire pop_owned  = (mode_eff != 2'd1);

  // -------------------------------------------------------------------------
  // AHB-Lite engine (hclk domain, one outstanding transfer)
  // -------------------------------------------------------------------------
  logic req_valid;   // address phase latched, data phase pending
  logic req_write;
  logic rd_cap;      // popped word present on rd_data; complete the read
  logic [DW-1:0] rd_data;

  // Address phase ends on the edge where HREADY is high.
  wire addr_valid = hresetn && hsel && htrans[1] && hready;

  // Only the AHB-owned side is driven; the other side's enable is forced low.
  wire ahb_push = req_valid && req_write && push_owned && !full;
  wire ahb_pop  = req_valid && !req_write && !rd_cap && pop_owned && !empty;

  // HREADYOUT: 1 when no data phase is pending or when it can complete now.
  // Reads owned by the AHB pop in this cycle and return data in the next one
  // (one wait state); reads not owned by the AHB complete with zero data.
  wire dphase_ready = !req_valid ? 1'b1 :
                      req_write  ? (push_owned ? !full  : 1'b1) :
                                   (pop_owned  ? rd_cap : 1'b1);
  assign hreadyout = dphase_ready;

  always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn) begin
      req_valid <= 1'b0;
      req_write <= 1'b0;
      rd_cap    <= 1'b0;
    end else begin
      if (rd_cap)         rd_cap <= 1'b0;
      else if (ahb_pop)   rd_cap <= 1'b1;

      // A completing data phase and the next address phase can coincide
      // (pipelined transfers); the new request wins.
      if (addr_valid) begin
        req_valid <= 1'b1;
        req_write <= hwrite;
      end else if (req_valid && dphase_ready) begin
        req_valid <= 1'b0;
      end
    end
  end

  always_comb begin
    if (req_valid && !req_write && rd_cap) hrdata = 32'(rd_data);
    else                                   hrdata = 32'd0;
  end

  assign hresp = 1'b0;

  // -------------------------------------------------------------------------
  // Core clock muxing and port ownership
  // -------------------------------------------------------------------------
  wire core_wr_clk = (mode_eff == 2'd2) ? wr_clk : hclk;
  wire core_rd_clk = (mode_eff == 2'd1) ? rd_clk : hclk;

  wire core_wr_en   = (mode_eff == 2'd2) ? ext_wr_en : ahb_push;
  wire [DW-1:0] core_wr_data = (mode_eff == 2'd2) ? ext_wr_data : hwdata[DW-1:0];
  wire core_rd_en   = (mode_eff == 2'd1) ? ext_rd_en : ahb_pop;

  assign ext_rd_data = rd_data;

  // -------------------------------------------------------------------------
  // FIFO core
  // -------------------------------------------------------------------------
  async_fifo #(
    .DW    (DW),
    .DEPTH (DEPTH)
  ) u_fifo (
    .wr_clk           (core_wr_clk),
    .wr_rst_n         (wr_rst_n),
    .wr_en            (core_wr_en),
    .wr_data          (core_wr_data),
    .full             (full),
    .rd_clk           (core_rd_clk),
    .rd_rst_n         (rd_rst_n),
    .rd_en            (core_rd_en),
    .rd_data          (rd_data),
    .empty            (empty),
    .cfg_clk          (cfg_clk),
    .cfg_rst_n        (cfg_presetn),
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
