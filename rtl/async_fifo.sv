// -----------------------------------------------------------------------------
// async_fifo.sv
// Fully-synthesizable Asynchronous (Dual-Clock) FIFO
// - Dual-clock: independent write and read clocks
// - CDC via 2-flop synchronizers + Gray-code pointers
// - Parameterizable data width and depth (power-of-two required)
// - Standard interface (wr_en, rd_en, full, empty, etc.)
// Design style: Cummings-style (SNUG 2002) with safe pointer comparison
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns/1ps

module async_fifo #(
    parameter int DW       = 8,     // Data width (bits)
    parameter int DEPTH    = 16,    // FIFO depth (must be power of two)
    parameter int ADDR_W   = $clog2(DEPTH)
) (
    // --- Write port ---
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,   // async assert, wr_clk-sync release
    input  wire                  wr_en,
    input  wire [DW-1:0]         wr_data,
    output wire                  full,

    // --- Read port ---
    input  wire                  rd_clk,
    input  wire                  rd_rst_n,   // async assert, rd_clk-sync release
    input  wire                  rd_en,
    output wire [DW-1:0]         rd_data,
    output wire                  empty,

    // --- Optional status (sync-crossed, approximate) ---
    output wire [ADDR_W:0]       wr_ptr_gray_sync,  // write pointer synced to read
    output wire [ADDR_W:0]       rd_ptr_gray_sync   // read pointer synced to write
);

  // -------------------------------------------------------------------------
  // Local params
  // -------------------------------------------------------------------------
  localparam int PTR_W = ADDR_W + 1;  // extra bit for full/empty disambiguation

  // -------------------------------------------------------------------------
  // Dual-port RAM
  // -------------------------------------------------------------------------
  logic [DW-1:0] mem [0:DEPTH-1];

  // Write-side pointers (binary + gray)
  logic [PTR_W-1:0] wr_ptr_bin, wr_ptr_gray;
  logic [PTR_W-1:0] wr_ptr_bin_next, wr_ptr_gray_next;

  // Read-side pointers (binary + gray)
  logic [PTR_W-1:0] rd_ptr_bin, rd_ptr_gray;
  logic [PTR_W-1:0] rd_ptr_bin_next, rd_ptr_gray_next;

  // Reset synchronizers: asynchronous assertion, synchronous release.
  (* ASYNC_REG = "TRUE" *) logic [1:0] wr_rst_sync;
  (* ASYNC_REG = "TRUE" *) logic [1:0] rd_rst_sync;
  wire wr_reset_n = wr_rst_sync[1];
  wire rd_reset_n = rd_rst_sync[1];

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) wr_rst_sync <= '0;
    else           wr_rst_sync <= {wr_rst_sync[0], 1'b1};
  end

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) rd_rst_sync <= '0;
    else           rd_rst_sync <= {rd_rst_sync[0], 1'b1};
  end

  // Synchronizer registers
  // rd_ptr_gray → wr_clk domain
  logic [PTR_W-1:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;
  // wr_ptr_gray → rd_clk domain
  logic [PTR_W-1:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;

  // Internal write/read enables (gated by full/empty)
  logic do_write, do_read;

  assign do_write = wr_reset_n && wr_en && !full;
  assign do_read  = rd_reset_n && rd_en && !empty;

  // =========================================================================
  // WRITE DOMAIN
  // =========================================================================

  // Next-pointer logic
  always_comb begin
    wr_ptr_bin_next  = wr_ptr_bin + {{(PTR_W-1){1'b0}}, do_write};
    wr_ptr_gray_next = wr_ptr_bin_next ^ (wr_ptr_bin_next >> 1);
  end

  // Pointer register
  always_ff @(posedge wr_clk or negedge wr_reset_n) begin
    if (!wr_reset_n) begin
      wr_ptr_bin  <= '0;
      wr_ptr_gray <= '0;
    end else begin
      wr_ptr_bin  <= wr_ptr_bin_next;
      wr_ptr_gray <= wr_ptr_gray_next;
    end
  end

  // Memory write
  always_ff @(posedge wr_clk) begin
    if (do_write) begin
      mem[wr_ptr_bin[ADDR_W-1:0]] <= wr_data;
    end
  end

  // Synchronize read-pointer gray into write domain
  always_ff @(posedge wr_clk or negedge wr_reset_n) begin
    if (!wr_reset_n) begin
      rd_ptr_gray_sync1 <= '0;
      rd_ptr_gray_sync2 <= '0;
    end else begin
      rd_ptr_gray_sync1 <= rd_ptr_gray;
      rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
    end
  end

  // Full flag: MSB and MSB-1 inverted, rest equal
  assign full = (wr_ptr_gray == {~rd_ptr_gray_sync2[PTR_W-1],
                                  ~rd_ptr_gray_sync2[PTR_W-2],
                                  rd_ptr_gray_sync2[PTR_W-3:0]});

  // =========================================================================
  // READ DOMAIN
  // =========================================================================

  // Next-pointer logic
  always_comb begin
    rd_ptr_bin_next  = rd_ptr_bin + {{(PTR_W-1){1'b0}}, do_read};
    rd_ptr_gray_next = rd_ptr_bin_next ^ (rd_ptr_bin_next >> 1);
  end

  // Pointer register
  always_ff @(posedge rd_clk or negedge rd_reset_n) begin
    if (!rd_reset_n) begin
      rd_ptr_bin  <= '0;
      rd_ptr_gray <= '0;
    end else begin
      rd_ptr_bin  <= rd_ptr_bin_next;
      rd_ptr_gray <= rd_ptr_gray_next;
    end
  end

  // Memory read (registered output — infers block RAM)
  logic [DW-1:0] rd_data_reg;

  always_ff @(posedge rd_clk) begin
    if (do_read)
      rd_data_reg <= mem[rd_ptr_bin[ADDR_W-1:0]];
  end

  assign rd_data = rd_data_reg;

  // Synchronize write-pointer gray into read domain
  always_ff @(posedge rd_clk or negedge rd_reset_n) begin
    if (!rd_reset_n) begin
      wr_ptr_gray_sync1 <= '0;
      wr_ptr_gray_sync2 <= '0;
    end else begin
      wr_ptr_gray_sync1 <= wr_ptr_gray;
      wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
    end
  end

  // Empty flag: pointers equal
  assign empty = (rd_ptr_gray == wr_ptr_gray_sync2);

  // Optional status outputs (already synchronized gray values)
  assign wr_ptr_gray_sync = wr_ptr_gray_sync2; // synced to read
  assign rd_ptr_gray_sync = rd_ptr_gray_sync2; // synced to write

  // -------------------------------------------------------------------------
  // Assertions (synthesis-safe — for simulation/formal)
  // -------------------------------------------------------------------------
`ifdef FORMAL
  // synthesis translate_off
  default property:
  assert property (@(posedge wr_clk) disable iff (!wr_reset_n)
    !(full && wr_en) |-> !full) else $error("Write when full!");
  assert property (@(posedge rd_clk) disable iff (!rd_reset_n)
    !(empty && rd_en) |-> !empty) else $error("Read when empty!");
  // synthesis translate_on
`endif

endmodule

`default_nettype wire
