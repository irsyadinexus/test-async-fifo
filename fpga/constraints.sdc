# constraints.sdc — Example SDC constraints for async FIFO
# Adjust clock names/periods to match your FPGA target.
#
# This file covers:
#   - Three independent clocks (wr_clk, rd_clk, cfg_clk)
#   - Asynchronous clock group declaration
#   - Reset constraints
#   - Configuration port and status output timing

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