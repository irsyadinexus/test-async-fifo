# constraints.sdc — Example SDC constraints for async FIFO
# Adjust clock names/periods to match your FPGA target.
#
# This file covers:
#   - Three independent clocks (wr_clk, rd_clk, cfg_clk)
#   - Asynchronous clock group declaration
#   - Reset constraints
#   - Configuration port and status output timing
#   - Wrapper clock inventories and clock groups (bus-wrapper section; templates
#     are commented because only one wrapper, if any, is instantiated)
#   - Wrapper reset fan-out and false paths (wrapper resets section)

# ---------------------------------------------------------------------------
# Write clock — 100 MHz
# ---------------------------------------------------------------------------
create_clock -name wr_clk -period 10.000 [get_ports wr_clk]

# ---------------------------------------------------------------------------
# Read clock — 62.5 MHz (non-harmonic example)
# ---------------------------------------------------------------------------
create_clock -name rd_clk -period 16.000 [get_ports rd_clk]

# ---------------------------------------------------------------------------
# Config clock — retune for your board (example: 125 MHz)
# ---------------------------------------------------------------------------
create_clock -name cfg_clk -period 8.000 [get_ports cfg_clk]

# ---------------------------------------------------------------------------
# Declare clocks as asynchronous
# ---------------------------------------------------------------------------
set_clock_groups -asynchronous \
  -group {wr_clk} \
  -group {rd_clk} \
  -group {cfg_clk}

# ---------------------------------------------------------------------------
# Reset (async assert, sync deassert inside each domain)
# ---------------------------------------------------------------------------
# Each reset is synchronized in its own clock domain, so the release edge is
# not a timing path between clocks.
set_false_path -from [get_ports wr_rst_n]
set_false_path -from [get_ports rd_rst_n]
set_false_path -from [get_ports cfg_rst_n]

# ---------------------------------------------------------------------------
# Input/output delays (example — tune for your board)
# ---------------------------------------------------------------------------
set_input_delay  -clock wr_clk 2.0 [get_ports {wr_en wr_data}]
set_input_delay  -clock rd_clk 2.0 [get_ports {rd_en}]
set_input_delay  -clock cfg_clk 2.0 [get_ports {cfg_we cfg_re cfg_addr cfg_wdata}]
set_output_delay -clock rd_clk 2.0 [get_ports {rd_data}]
set_output_delay -clock wr_clk 2.0 [get_ports {full}]
set_output_delay -clock rd_clk 2.0 [get_ports {empty}]
set_output_delay -clock cfg_clk 2.0 [get_ports {cfg_rdata irq}]
set_output_delay -clock wr_clk 2.0 [get_ports almost_full]
set_output_delay -clock rd_clk 2.0 [get_ports almost_empty]

# ---------------------------------------------------------------------------
# CDC skew control for Gray pointer/config buses (Vivado-style example; adapt
# object filters and the delay value to your tool and destination period):
# set_max_delay -datapath_only \
#   -from [get_cells -hierarchical -filter {PRIMITIVE_GROUP =~ FLOP && NAME =~ *gray*}] \
#   -to   [get_cells -hierarchical -filter {PRIMITIVE_GROUP =~ FLOP && NAME =~ *sync1*}] \
#   10.000

# ---------------------------------------------------------------------------
# Bus wrappers (rtl/fifo_apb_wrapper.sv, rtl/fifo_ahb_wrapper.sv,
# rtl/fifo_axis_wrapper.sv)
# ---------------------------------------------------------------------------
# The wrappers rename the clock and reset pins and add bus ports. Only one
# wrapper is normally instantiated, and create_clock on a port that does not
# exist fails in most tools, so each block below is a template: uncomment the
# block for the wrapper you use, or retarget get_ports to hierarchical pins when
# the wrapper is not the top level.
#
# Clock inventories:
#   APB wrapper         pclk         holds the FIFO write, read, and config
#                                    domains plus the APB slave
#   AHB wrapper         hclk         AHB engine and every FIFO side it owns
#                       cfg_clk      configuration port and the MODE register
#                       wr_clk       raw write side, released only in MODE 2
#                       rd_clk       raw read side, released only in MODE 1
#   AXI-Stream wrapper  aclk         AXI4-Lite config port and FIFO config domain
#                       s_axis_aclk  FIFO write side
#                       m_axis_aclk  FIFO read side
#
# In every wrapper the core's two-stage synchronizers remain the only CDC paths,
# so the asynchronous clock groups below mirror the core declaration above. All
# wrapper resets are asynchronous-assert, per-domain synchronized release, like
# the core resets.

# --- APB wrapper: one clock domain, nothing asynchronous to declare ----------
# create_clock -name pclk -period 10.000 [get_ports pclk]
# Reset: presetn -> see the wrapper resets block below
# set_input_delay  -clock pclk 2.0 [get_ports {psel penable pwrite paddr pwdata}]
# set_output_delay -clock pclk 2.0 [get_ports {prdata pready pslverr}]
# set_output_delay -clock pclk 2.0 [get_ports {irq almost_full almost_empty}]
# set_output_delay -clock pclk 2.0 [get_ports {wr_ptr_gray_sync rd_ptr_gray_sync}]

# --- AHB wrapper: hclk, cfg_clk, and the two optional raw-side clocks --------
# create_clock -name hclk    -period 10.000 [get_ports hclk]
# create_clock -name cfg_clk -period 14.000 [get_ports cfg_clk]
# create_clock -name wr_clk  -period 40.000 [get_ports wr_clk]
# create_clock -name rd_clk  -period 26.000 [get_ports rd_clk]
#
# MODE (configuration offset 9) is quasi-static: it selects the FIFO clock muxes.
# The select is a register, so STA cannot prove the mux static and propagates all
# of its inputs: every raw-side clock that exists reaches the core's clock pins in
# every mode, and all of them must be created and grouped as asynchronous.
#
#   MODE  AHB owns    core wr_clk  core rd_clk  hold on change
#   0     push + pop  hclk         hclk         none
#   1     push        hclk         rd_clk       rd_rst_n
#   2     pop         wr_clk       hclk         wr_rst_n
#   3     as 0        hclk         hclk         none
#
# "hold on change" names the reset of the side that mode moves off hclk. Hold the
# union of that column for the mode you leave and the mode you enter: 0 <-> 1
# holds rd_rst_n, 2 <-> 3 holds wr_rst_n, 1 <-> 2 holds both. That is a sequencing
# rule, not a timing constraint (see "Reset" in doc/design.md).
#
# set_clock_groups -asynchronous -group {hclk} -group {cfg_clk} \
#   -group {wr_clk} -group {rd_clk}
#
# If a raw side is not routed at all (its pins tied to hclk/hresetn), omit that
# clock's create_clock line and its -group clause together; a -group naming a
# clock that was never created is an error in most tools.
#
# Optional: collapse the mux to the configured mode so the unused branch is not
# analyzed. Re-apply it whenever MODE changes. The command is tool-specific; this
# is the Vivado form for MODE 0 (both bits zero, so both sides select hclk):
# set_case_analysis 0 [get_pins -hierarchical *mode_q_reg[1]/Q]
# set_case_analysis 0 [get_pins -hierarchical *mode_q_reg[0]/Q]
#
# Reset: hresetn / cfg_presetn / wr_rst_n / rd_rst_n -> see the wrapper resets
# block below. hresetn resets the AHB engine only, not the FIFO.
#
# AHB channel (address phase and data phase both close on hclk):
# set_input_delay  -clock hclk 2.0 [get_ports {hsel htrans hwrite hsize haddr hwdata hready}]
# set_output_delay -clock hclk 2.0 [get_ports {hrdata hreadyout hresp}]
#
# Configuration channel:
# set_input_delay  -clock cfg_clk 2.0 [get_ports {cfg_psel cfg_penable cfg_pwrite}]
# set_input_delay  -clock cfg_clk 2.0 [get_ports {cfg_paddr cfg_pwdata}]
# set_output_delay -clock cfg_clk 2.0 [get_ports {cfg_prdata cfg_pready irq}]
#
# Raw side:
# set_input_delay  -clock wr_clk 2.0 [get_ports {ext_wr_en ext_wr_data}]
# set_input_delay  -clock rd_clk 2.0 [get_ports {ext_rd_en}]
# set_output_delay -clock rd_clk 2.0 [get_ports {ext_rd_data}]
#
# Status and pointer outputs follow the MODE mux, so constrain them with the
# clock that owns them in the configured mode:
#   MODE 0/3 (default): full empty almost_full almost_empty   -> hclk
#                       wr_ptr_gray_sync (read domain)        -> hclk
#                       rd_ptr_gray_sync (write domain)       -> hclk
#   MODE 1:             empty almost_empty wr_ptr_gray_sync   -> rd_clk
#   MODE 2:             full almost_full rd_ptr_gray_sync     -> wr_clk
# set_output_delay -clock hclk 2.0 [get_ports {full empty almost_full almost_empty}]
# set_output_delay -clock hclk 2.0 [get_ports {wr_ptr_gray_sync rd_ptr_gray_sync}]
#
# The wrapper's MODE register (configuration offset 9) is clocked by cfg_clk and
# only changes with the data-domain resets asserted, so no timing path needs to
# close from it to the clock muxes. If your tool reports such a path, mark it as
# a false path (object names are tool-specific):
# set_false_path -from [get_cells -hierarchical -filter {NAME =~ *mode_q_reg*}] \
#   -to [get_pins -hierarchical -filter {NAME =~ *u_fifo/wr_clk* || NAME =~ *u_fifo/rd_clk*}]

# --- AXI-Stream wrapper: three independent clock domains ---------------------
# create_clock -name aclk        -period 12.000 [get_ports aclk]
# create_clock -name s_axis_aclk -period 10.000 [get_ports s_axis_aclk]
# create_clock -name m_axis_aclk -period 14.000 [get_ports m_axis_aclk]
# set_clock_groups -asynchronous \
#   -group {aclk} -group {s_axis_aclk} -group {m_axis_aclk}
# Reset: aresetn / s_axis_aresetn / m_axis_aresetn -> see the wrapper resets
# block below.
#
# AXI4-Lite configuration channel:
# set_input_delay  -clock aclk 2.0 [get_ports {awaddr awvalid wdata wvalid bready}]
# set_input_delay  -clock aclk 2.0 [get_ports {araddr arvalid rready}]
# set_output_delay -clock aclk 2.0 [get_ports {awready wready bresp bvalid}]
# set_output_delay -clock aclk 2.0 [get_ports {arready rdata rresp rvalid irq}]
#
# Streams (tready is the only output on the slave side, tvalid/tdata on the
# master side):
# set_input_delay  -clock s_axis_aclk 2.0 [get_ports {s_axis_tvalid s_axis_tdata}]
# set_output_delay -clock s_axis_aclk 2.0 [get_ports {s_axis_tready}]
# set_output_delay -clock s_axis_aclk 2.0 [get_ports {almost_full rd_ptr_gray_sync}]
# set_output_delay -clock m_axis_aclk 2.0 [get_ports {m_axis_tvalid m_axis_tdata}]
# set_input_delay  -clock m_axis_aclk 2.0 [get_ports {m_axis_tready}]
# set_output_delay -clock m_axis_aclk 2.0 [get_ports {almost_empty wr_ptr_gray_sync}]

# ---------------------------------------------------------------------------
# Wrapper resets
# ---------------------------------------------------------------------------
# Reset fan-out per wrapper (see "Reset" in doc/design.md):
#   APB        presetn          FIFO write, read, and config domains, plus the
#                               wrapper's pop state machine
#   AHB        hresetn          AHB engine only: latched request, read capture,
#                               and address-phase gating. Does NOT reset the FIFO
#   AHB        cfg_presetn      core cfg_rst_n and the MODE register
#   AHB        wr_rst_n         raw write side, driven only in MODE 2
#   AHB        rd_rst_n         raw read side, driven only in MODE 1
#   AXI-Stream aresetn          core cfg_rst_n and the AXI4-Lite reset synchronizer
#   AXI-Stream s_axis_aresetn   FIFO write side and the stream/pipeline reset
#                               synchronizers of that domain
#   AXI-Stream m_axis_aresetn   FIFO read side and the stream/pipeline reset
#                               synchronizers of that domain
#
# Every pin asserts asynchronously and is released synchronously in the domain it
# resets: either a wrapper-local two-stage synchronizer (AXI-Stream config and
# both stream domains) or the core's internal per-domain synchronizer. No path
# from these ports has to be timed, so each is a false path. Uncomment the lines
# for the wrapper you instantiate.
#
# APB
# set_false_path -from [get_ports presetn]
#
# AHB
# set_false_path -from [get_ports hresetn]
# set_false_path -from [get_ports cfg_presetn]
# set_false_path -from [get_ports {wr_rst_n rd_rst_n}]
#
# AXI-Stream
# set_false_path -from [get_ports aresetn]
# set_false_path -from [get_ports {s_axis_aresetn m_axis_aresetn}]
#
# Release takes two clocks of the destination domain. A push issued before that
# completes is accepted by the wrapper (full reads low) and dropped by the core,
# so the bus master must stay idle for those two clocks. That is a sequencing
# rule, not a timing constraint; see "Reset" in doc/design.md.
