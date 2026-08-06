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

    input  wire                  cfg_clk,
    input  wire                  cfg_rst_n,
    input  wire                  cfg_we,
    input  wire                  cfg_re,
    input  wire [3:0]            cfg_addr,
    input  wire [ADDR_W:0]       cfg_wdata,
    output logic [ADDR_W:0]       cfg_rdata,
    output wire                  irq,
    output wire                  almost_empty,
    output wire                  almost_full,

    // --- Optional status (sync-crossed, approximate) ---
    output wire [ADDR_W:0]       wr_ptr_gray_sync,  // write pointer synced to read
    output wire [ADDR_W:0]       rd_ptr_gray_sync   // read pointer synced to write
);

  // -------------------------------------------------------------------------
  // Local params
  // -------------------------------------------------------------------------
  localparam int PTR_W = ADDR_W + 1;  // extra bit for full/empty disambiguation
  localparam int unsigned AE_DEFAULT_INT = (DEPTH + 4) / 5;
  localparam int unsigned AF_DEFAULT_INT = (4 * DEPTH + 4) / 5;
  localparam logic [PTR_W-1:0] AE_DEFAULT = PTR_W'(AE_DEFAULT_INT);
  localparam logic [PTR_W-1:0] AF_DEFAULT = PTR_W'(AF_DEFAULT_INT);
  localparam logic [PTR_W-1:0] DEPTH_VALUE = PTR_W'(DEPTH);

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

  logic [PTR_W-1:0] ae_cfg_gray, af_cfg_gray;
  logic [PTR_W-1:0] depth_cfg_gray;
  (* ASYNC_REG = "TRUE" *) logic [PTR_W-1:0] ae_gray_sync1, ae_gray_sync2;
  (* ASYNC_REG = "TRUE" *) logic [PTR_W-1:0] af_gray_sync1, af_gray_sync2;
  logic [PTR_W-1:0] ae_threshold, af_threshold;
  (* ASYNC_REG = "TRUE" *) logic [PTR_W-1:0] depth_gray_sync1, depth_gray_sync2;
  logic [PTR_W-1:0] active_depth;
  logic [3:0] irq_mask;
  logic overflow_sticky, underflow_sticky;
  logic [1:0] overflow_cfg_sync, underflow_cfg_sync;
  logic overflow_clear_toggle, underflow_clear_toggle;
  logic [1:0] overflow_clear_sync, underflow_clear_sync;
  logic overflow_clear_seen, underflow_clear_seen;
  logic flush_req_toggle;
  logic [1:0] flush_wr_sync, flush_rd_sync;
  logic flush_wr_seen, flush_rd_seen;
  logic [1:0] flush_wr_ack_sync, flush_rd_ack_sync;
  wire flush_busy = (flush_wr_ack_sync[1] != flush_req_toggle) ||
                    (flush_rd_ack_sync[1] != flush_req_toggle);
  (* ASYNC_REG = "TRUE" *) logic [PTR_W-1:0] wr_ptr_cfg_sync1, wr_ptr_cfg_sync2;
  (* ASYNC_REG = "TRUE" *) logic [PTR_W-1:0] rd_ptr_cfg_sync1, rd_ptr_cfg_sync2;
  (* ASYNC_REG = "TRUE" *) logic [1:0] full_cfg_sync, empty_cfg_sync;
  (* ASYNC_REG = "TRUE" *) logic [1:0] af_cfg_sync, ae_cfg_sync;
  wire [3:0] irq_status = {ae_cfg_sync[1], af_cfg_sync[1],
                           empty_cfg_sync[1], full_cfg_sync[1]};
  assign irq = |(irq_status & irq_mask);

  function automatic logic [PTR_W-1:0] bin_to_gray(input logic [PTR_W-1:0] bin);
    return bin ^ (bin >> 1);
  endfunction

  function automatic logic [PTR_W-1:0] gray_to_bin(input logic [PTR_W-1:0] gray);
    logic [PTR_W-1:0] bin;
    bin[PTR_W-1] = gray[PTR_W-1];
    for (int i = PTR_W-2; i >= 0; i--)
      bin[i] = bin[i+1] ^ gray[i];
    return bin;
  endfunction

  always_ff @(posedge cfg_clk or negedge cfg_rst_n) begin
    if (!cfg_rst_n) begin
      ae_cfg_gray <= bin_to_gray(AE_DEFAULT);
      af_cfg_gray <= bin_to_gray(AF_DEFAULT);
      depth_cfg_gray <= bin_to_gray(DEPTH_VALUE);
      irq_mask <= '0;
      overflow_clear_toggle <= 1'b0;
      underflow_clear_toggle <= 1'b0;
      flush_req_toggle <= 1'b0;
    end else if (cfg_we) begin
      case (cfg_addr)
        4'd0: ae_cfg_gray <= bin_to_gray((cfg_wdata > DEPTH_VALUE) ? DEPTH_VALUE : cfg_wdata);
        4'd1: af_cfg_gray <= bin_to_gray((cfg_wdata > DEPTH_VALUE) ? DEPTH_VALUE : cfg_wdata);
        4'd2: begin
          case (cfg_wdata[1:0])
            2'd0: depth_cfg_gray <= bin_to_gray(DEPTH_VALUE);
            2'd1: depth_cfg_gray <= bin_to_gray(PTR_W'((DEPTH * 3) / 4));
            2'd2: depth_cfg_gray <= bin_to_gray(PTR_W'(DEPTH / 2));
            2'd3: depth_cfg_gray <= bin_to_gray(PTR_W'(DEPTH / 4));
          endcase
        end
        4'd3: irq_mask <= cfg_wdata[3:0];
        4'd5: begin
          if (cfg_wdata[0]) overflow_clear_toggle <= ~overflow_clear_toggle;
          if (cfg_wdata[1]) underflow_clear_toggle <= ~underflow_clear_toggle;
        end
        4'd8: if (cfg_wdata[0] && !flush_busy)
                flush_req_toggle <= ~flush_req_toggle;
        default: ;
      endcase
    end
  end

  always_ff @(posedge cfg_clk or negedge cfg_rst_n) begin
    if (!cfg_rst_n) begin
      full_cfg_sync  <= '0;
      empty_cfg_sync <= '0;
      af_cfg_sync    <= '0;
      ae_cfg_sync    <= '0;
      overflow_cfg_sync <= '0;
      underflow_cfg_sync <= '0;
      wr_ptr_cfg_sync1 <= '0;
      wr_ptr_cfg_sync2 <= '0;
      rd_ptr_cfg_sync1 <= '0;
      rd_ptr_cfg_sync2 <= '0;
      flush_wr_ack_sync <= '0;
      flush_rd_ack_sync <= '0;
    end else begin
      full_cfg_sync  <= {full_cfg_sync[0], full};
      empty_cfg_sync <= {empty_cfg_sync[0], empty};
      af_cfg_sync    <= {af_cfg_sync[0], almost_full};
      ae_cfg_sync    <= {ae_cfg_sync[0], almost_empty};
      overflow_cfg_sync <= {overflow_cfg_sync[0], overflow_sticky};
      underflow_cfg_sync <= {underflow_cfg_sync[0], underflow_sticky};
      wr_ptr_cfg_sync1 <= wr_ptr_gray;
      wr_ptr_cfg_sync2 <= wr_ptr_cfg_sync1;
      rd_ptr_cfg_sync1 <= rd_ptr_gray;
      rd_ptr_cfg_sync2 <= rd_ptr_cfg_sync1;
      flush_wr_ack_sync <= {flush_wr_ack_sync[0], flush_wr_seen};
      flush_rd_ack_sync <= {flush_rd_ack_sync[0], flush_rd_seen};
    end
  end

  always @* begin
    cfg_rdata = '0;
    if (cfg_re) begin
      case (cfg_addr)
        4'd0: cfg_rdata = gray_to_bin(ae_cfg_gray);
        4'd1: cfg_rdata = gray_to_bin(af_cfg_gray);
        4'd2: cfg_rdata = active_depth;
        4'd3: cfg_rdata = PTR_W'(irq_mask);
        4'd4: cfg_rdata = PTR_W'(irq_status);
        4'd5: cfg_rdata = PTR_W'({underflow_cfg_sync[1], overflow_cfg_sync[1]});
        4'd6: cfg_rdata = gray_to_bin(wr_ptr_cfg_sync2) - gray_to_bin(rd_ptr_cfg_sync2);
        4'd7: cfg_rdata = gray_to_bin(wr_ptr_cfg_sync2) - gray_to_bin(rd_ptr_cfg_sync2);
        4'd8: cfg_rdata = PTR_W'(flush_busy);
        default: cfg_rdata = '0;
      endcase
    end
  end

  // Reset synchronizers: asynchronous assertion, synchronous release.
  (* ASYNC_REG = "TRUE" *) logic [1:0] wr_rst_sync;
  (* ASYNC_REG = "TRUE" *) logic [1:0] rd_rst_sync;
  wire wr_reset_n = wr_rst_sync[1];
  wire rd_reset_n = rd_rst_sync[1];

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) wr_rst_sync <= '0;
    else           wr_rst_sync <= {wr_rst_sync[0], 1'b1};
  end

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n)
      {depth_gray_sync2, depth_gray_sync1} <= {2{bin_to_gray(DEPTH_VALUE)}};
    else
      {depth_gray_sync2, depth_gray_sync1} <= {depth_gray_sync1, depth_cfg_gray};
  end

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) rd_rst_sync <= '0;
    else           rd_rst_sync <= {rd_rst_sync[0], 1'b1};
  end

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n)
      {af_gray_sync2, af_gray_sync1} <= {2{bin_to_gray(AF_DEFAULT)}};
    else
      {af_gray_sync2, af_gray_sync1} <= {af_gray_sync1, af_cfg_gray};
  end

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n)
      {ae_gray_sync2, ae_gray_sync1} <= {2{bin_to_gray(AE_DEFAULT)}};
    else
      {ae_gray_sync2, ae_gray_sync1} <= {ae_gray_sync1, ae_cfg_gray};
  end

  always_comb begin
    af_threshold = gray_to_bin(af_gray_sync2);
    ae_threshold = gray_to_bin(ae_gray_sync2);
    active_depth = gray_to_bin(depth_gray_sync2);
  end

  // Synchronizer registers
  // rd_ptr_gray → wr_clk domain
  logic [PTR_W-1:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;
  // wr_ptr_gray → rd_clk domain
  logic [PTR_W-1:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;

  // Internal write/read enables (gated by full/empty)
  logic do_write, do_read;

  assign do_write = wr_reset_n && wr_en && !full &&
                    (flush_wr_sync[1] == flush_wr_seen);
  assign do_read  = rd_reset_n && rd_en && !empty &&
                    (flush_rd_sync[1] == flush_rd_seen);

  // Sticky access errors. W1C requests cross back as toggles, preventing a
  // narrow cfg_clk pulse from being missed by either asynchronous domain.
  always_ff @(posedge wr_clk or negedge wr_reset_n) begin
    if (!wr_reset_n) begin
      overflow_clear_sync <= '0;
      overflow_clear_seen <= 1'b0;
      overflow_sticky <= 1'b0;
    end else begin
      overflow_clear_sync <= {overflow_clear_sync[0], overflow_clear_toggle};
      overflow_clear_seen <= overflow_clear_sync[1];
      if (overflow_clear_sync[1] != overflow_clear_seen) overflow_sticky <= 1'b0;
      if (wr_en && full) overflow_sticky <= 1'b1;
    end
  end

  always_ff @(posedge rd_clk or negedge rd_reset_n) begin
    if (!rd_reset_n) begin
      underflow_clear_sync <= '0;
      underflow_clear_seen <= 1'b0;
      underflow_sticky <= 1'b0;
    end else begin
      underflow_clear_sync <= {underflow_clear_sync[0], underflow_clear_toggle};
      underflow_clear_seen <= underflow_clear_sync[1];
      if (underflow_clear_sync[1] != underflow_clear_seen) underflow_sticky <= 1'b0;
      if (rd_en && empty) underflow_sticky <= 1'b1;
    end
  end

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
      flush_wr_sync <= '0;
      flush_wr_seen <= 1'b0;
    end else begin
      flush_wr_sync <= {flush_wr_sync[0], flush_req_toggle};
      if (flush_wr_sync[1] != flush_wr_seen) begin
        wr_ptr_bin <= '0;
        wr_ptr_gray <= '0;
        flush_wr_seen <= flush_wr_sync[1];
      end else begin
        wr_ptr_bin  <= wr_ptr_bin_next;
        wr_ptr_gray <= wr_ptr_gray_next;
      end
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
  logic [PTR_W-1:0] rd_ptr_bin_sync;
  always_comb begin
    rd_ptr_bin_sync[PTR_W-1] = rd_ptr_gray_sync2[PTR_W-1];
    for (int i = PTR_W-2; i >= 0; i--)
      rd_ptr_bin_sync[i] = rd_ptr_bin_sync[i+1] ^ rd_ptr_gray_sync2[i];
  end
  assign full = ((wr_ptr_bin - rd_ptr_bin_sync) >= active_depth);
  assign almost_full = ((wr_ptr_bin - rd_ptr_bin_sync) >= af_threshold);

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
      flush_rd_sync <= '0;
      flush_rd_seen <= 1'b0;
    end else begin
      flush_rd_sync <= {flush_rd_sync[0], flush_req_toggle};
      if (flush_rd_sync[1] != flush_rd_seen) begin
        rd_ptr_bin <= '0;
        rd_ptr_gray <= '0;
        flush_rd_seen <= flush_rd_sync[1];
      end else begin
        rd_ptr_bin  <= rd_ptr_bin_next;
        rd_ptr_gray <= rd_ptr_gray_next;
      end
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

  logic [PTR_W-1:0] wr_ptr_bin_sync;
  always_comb begin
    wr_ptr_bin_sync[PTR_W-1] = wr_ptr_gray_sync2[PTR_W-1];
    for (int i = PTR_W-2; i >= 0; i--)
      wr_ptr_bin_sync[i] = wr_ptr_bin_sync[i+1] ^ wr_ptr_gray_sync2[i];
  end
  assign almost_empty = ((wr_ptr_bin_sync - rd_ptr_bin) <= ae_threshold);

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
