// -----------------------------------------------------------------------------
// fifo_apb_cfg.sv
// Combinational APB -> async_fifo configuration-port bridge
// - Zero-wait-state APB slave for the FIFO configuration register window
// - No clock and no state: pure combinational decode of one APB access
// - Forwards all 16 word offsets; the core ignores reserved addresses
//   (including offset 9) through its existing `default:` decode arm
// - PREADY is constant 1, PSEL/PENABLE access phase is one cycle wide, so a
//   register write produces exactly one cfg_we pulse
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns/1ps

module fifo_apb_cfg #(
    parameter int PTR_W = 9         // = ADDR_W+1, matches async_fifo cfg width
) (
    // APB slave (configuration register window only)
    input  wire              psel,
    input  wire              penable,
    input  wire              pwrite,
    input  wire [3:0]        paddr,   // word offset 0..15
    input  wire [31:0]       pwdata,
    output logic [31:0]      prdata,
    output wire              pready,

    // async_fifo configuration port
    output wire              cfg_we,
    output wire              cfg_re,
    output wire [3:0]        cfg_addr,
    output wire [PTR_W-1:0]  cfg_wdata,
    input  wire [PTR_W-1:0]  cfg_rdata
);

  // Access-phase write strobe: one cycle, one core register write.
  assign cfg_we    = psel && penable && pwrite;

  // The core gates its combinational cfg_rdata with cfg_re, so assert it for
  // the whole read transfer (setup and access phase) and let the master sample
  // prdata at the completing edge.
  assign cfg_re    = psel && !pwrite;

  assign cfg_addr  = paddr;
  assign cfg_wdata = pwdata[PTR_W-1:0];

  assign pready    = 1'b1;
  assign prdata    = (psel && !pwrite) ? 32'(cfg_rdata) : 32'd0;

endmodule

`default_nettype wire
