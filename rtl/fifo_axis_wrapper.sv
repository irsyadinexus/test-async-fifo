// -----------------------------------------------------------------------------
// fifo_axis_wrapper.sv
// AXI-Stream + AXI4-Lite wrapper for async_fifo
// - s_axis: FIFO write side on s_axis_aclk (tready = !full)
// - m_axis: FIFO read side on m_axis_aclk through a two-entry output pipeline
//   (skid register plus direct bypass of the core's registered read data), so
//   the stream sustains one word per cycle with tready held high and absorbs
//   backpressure without loss or duplication
// - AXI4-Lite config slave on its own clock (aclk) for registers 0..8
// - No TLAST/TKEEP/TSTRB: the FIFO has no packet semantics
// - Writes to reserved config offsets are forwarded and ignored by the core
//
// The core read data is registered, so a popped word appears on rd_data one
// m_axis_aclk cycle after rd_en. The pipeline therefore treats rd_data as
// stage 1 (`s1_full`) and the skid register as stage 2 (`out_valid`):
//   m_axis_tvalid = s1_full | out_valid
//   m_axis_tdata  = out_valid ? out_data : rd_data
// which presents the oldest word first and needs no extra latency.
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns/1ps

module fifo_axis_wrapper #(
    parameter int DW     = 8,
    parameter int DEPTH  = 16,
    parameter int ADDR_W = $clog2(DEPTH)
) (
    // AXI4-Lite config slave
    input  wire           aclk,
    input  wire           aresetn,
    input  wire [31:0]    awaddr,
    input  wire           awvalid,
    output wire           awready,
    input  wire [31:0]    wdata,
    input  wire           wvalid,
    output wire           wready,
    output wire [1:0]     bresp,
    output wire           bvalid,
    input  wire           bready,
    input  wire [31:0]    araddr,
    input  wire           arvalid,
    output wire           arready,
    output logic [31:0]   rdata,
    output wire [1:0]     rresp,
    output wire           rvalid,
    input  wire           rready,

    // AXI-Stream slave (FIFO write side)
    input  wire           s_axis_aclk,
    input  wire           s_axis_aresetn,
    input  wire           s_axis_tvalid,
    input  wire [DW-1:0]  s_axis_tdata,
    output wire           s_axis_tready,

    // AXI-Stream master (FIFO read side)
    input  wire           m_axis_aclk,
    input  wire           m_axis_aresetn,
    output wire           m_axis_tvalid,
    output wire [DW-1:0]  m_axis_tdata,
    input  wire           m_axis_tready,

    // Status
    output wire           irq,
    output wire           almost_full,
    output wire           almost_empty,
    output wire [ADDR_W:0] wr_ptr_gray_sync,
    output wire [ADDR_W:0] rd_ptr_gray_sync
);

  localparam int PTR_W = ADDR_W + 1;

  // -------------------------------------------------------------------------
  // AXI4-Lite config slave (aclk domain)
  // -------------------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) logic [1:0] a_rst_sync;
  wire a_reset_n = a_rst_sync[1];

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) a_rst_sync <= '0;
    else          a_rst_sync <= {a_rst_sync[0], 1'b1};
  end

  logic        aw_pending, w_pending;
  logic [31:0] awaddr_q, wdata_q;
  logic        bvalid_q, rvalid_q;

  // Write address and data are latched independently and executed together, so
  // an address that changes after its own handshake cannot be misused.
  wire wr_exec = aw_pending && w_pending;

  assign awready = a_reset_n && !bvalid_q && !aw_pending;
  assign wready  = a_reset_n && !bvalid_q && !w_pending;

  // One configuration access per cycle: a read is granted only when no write
  // is executing, so cfg_addr has a single driver.
  assign arready = a_reset_n && !rvalid_q && !wr_exec;
  wire   ar_hs   = arvalid && arready;

  wire        cfg_we    = wr_exec;
  wire        cfg_re    = ar_hs;
  wire [3:0]  cfg_addr  = ar_hs ? araddr[5:2] : awaddr_q[5:2];
  wire [PTR_W-1:0] cfg_wdata = wdata_q[PTR_W-1:0];
  logic [PTR_W-1:0] cfg_rdata;

  assign bresp = 2'b00;
  assign rresp = 2'b00;
  assign bvalid = bvalid_q;
  assign rvalid = rvalid_q;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      aw_pending <= 1'b0;
      w_pending  <= 1'b0;
      awaddr_q   <= '0;
      wdata_q    <= '0;
      bvalid_q   <= 1'b0;
      rvalid_q   <= 1'b0;
      rdata      <= '0;
    end else begin
      if (awvalid && awready)   begin aw_pending <= 1'b1; awaddr_q <= awaddr; end
      else if (wr_exec)              aw_pending <= 1'b0;

      if (wvalid && wready)     begin w_pending  <= 1'b1; wdata_q  <= wdata;  end
      else if (wr_exec)              w_pending  <= 1'b0;

      if (wr_exec)                   bvalid_q   <= 1'b1;
      else if (bvalid_q && bready)   bvalid_q   <= 1'b0;

      if (ar_hs)                     begin rvalid_q <= 1'b1; rdata <= 32'(cfg_rdata); end
      else if (rvalid_q && rready)   rvalid_q   <= 1'b0;
    end
  end

  // -------------------------------------------------------------------------
  // Stream domains: local reset synchronizers
  // -------------------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) logic [1:0] s_rst_sync;
  (* ASYNC_REG = "TRUE" *) logic [1:0] m_rst_sync;
  wire s_reset_n = s_rst_sync[1];
  wire m_reset_n = m_rst_sync[1];

  always_ff @(posedge s_axis_aclk or negedge s_axis_aresetn) begin
    if (!s_axis_aresetn) s_rst_sync <= '0;
    else                 s_rst_sync <= {s_rst_sync[0], 1'b1};
  end

  always_ff @(posedge m_axis_aclk or negedge m_axis_aresetn) begin
    if (!m_axis_aresetn) m_rst_sync <= '0;
    else                 m_rst_sync <= {m_rst_sync[0], 1'b1};
  end

  // -------------------------------------------------------------------------
  // s_axis: push
  // -------------------------------------------------------------------------
  logic        full, empty;
  wire [DW-1:0] rd_data;

  assign s_axis_tready = s_reset_n && !full;
  wire   wr_en = s_axis_tvalid && s_axis_tready;

  // -------------------------------------------------------------------------
  // m_axis: two-entry output pipeline (skid register + core read data bypass)
  // -------------------------------------------------------------------------
  logic        out_valid;      // skid register holds a word
  logic [DW-1:0] out_data;
  logic        s1_full;        // rd_data holds a popped word

  wire s2_free = !out_valid || m_axis_tready;

  // Issue a pop when stage 1 is free, or when its word is leaving this cycle.
  wire pop_issue = m_reset_n && !empty && (!s1_full || s2_free);

  // The word in stage 1 is delivered straight to the bus when the skid is
  // empty and the sink is ready; otherwise it moves into the skid.
  wire direct  = s1_full && !out_valid && m_axis_tready;
  wire capture = s1_full && s2_free && !direct;

  assign m_axis_tvalid = s1_full || out_valid;
  assign m_axis_tdata  = out_valid ? out_data : rd_data;

  always_ff @(posedge m_axis_aclk or negedge m_axis_aresetn) begin
    if (!m_axis_aresetn) begin
      s1_full   <= 1'b0;
      out_valid <= 1'b0;
      out_data  <= '0;
    end else if (!m_reset_n) begin
      s1_full   <= 1'b0;
      out_valid <= 1'b0;
    end else begin
      // Stage 1 holds a popped word until it is delivered to the bus or moved
      // into the skid register; a new pop refills it on the next cycle.
      s1_full <= pop_issue || (s1_full && !capture && !direct);
      if (capture) begin
        out_data  <= rd_data;
        out_valid <= 1'b1;
      end else if (out_valid && m_axis_tready) begin
        out_valid <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // FIFO core
  // -------------------------------------------------------------------------
  async_fifo #(
    .DW    (DW),
    .DEPTH (DEPTH)
  ) u_fifo (
    .wr_clk           (s_axis_aclk),
    .wr_rst_n         (s_axis_aresetn),
    .wr_en            (wr_en),
    .wr_data          (s_axis_tdata),
    .full             (full),
    .rd_clk           (m_axis_aclk),
    .rd_rst_n         (m_axis_aresetn),
    .rd_en            (pop_issue),
    .rd_data          (rd_data),
    .empty            (empty),
    .cfg_clk          (aclk),
    .cfg_rst_n        (aresetn),
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
