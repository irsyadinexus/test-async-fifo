# constraints.sdc — Example SDC constraints for async FIFO
# Adjust clock names/periods to match your FPGA target.
#
# This file covers:
#   - Two independent clocks (wr_clk, rd_clk)
#   - Asynchronous clock group declaration
#   - Reset constraints

# ---------------------------------------------------------------------------
# Write clock — 100 MHz
# ---------------------------------------------------------------------------
create_clock -name wr_clk -period 10.000 [get_ports wr_clk]

# ---------------------------------------------------------------------------
# Read clock — 62.5 MHz (non-harmonic example)
# ---------------------------------------------------------------------------
create_clock -name rd_clk -period 16.000 [get_ports rd_clk]

# ---------------------------------------------------------------------------
# Declare clocks as asynchronous
# ---------------------------------------------------------------------------
set_clock_groups -asynchronous \
  -group {wr_clk} \
  -group {rd_clk}

# ---------------------------------------------------------------------------
# Reset (async assert, sync deassert recommended)
# ---------------------------------------------------------------------------
# wr_rst_n and rd_rst_n should each be false-path checked
set_false_path -from [get_ports wr_rst_n] -to [get_clocks wr_clk]
set_false_path -from [get_ports rd_rst_n] -to [get_clocks rd_clk]

# ---------------------------------------------------------------------------
# Input/output delays (example — tune for your board)
# ---------------------------------------------------------------------------
set_input_delay  -clock wr_clk 2.0 [get_ports {wr_en wr_data}]
set_input_delay  -clock rd_clk 2.0 [get_ports {rd_en}]
set_output_delay -clock rd_clk 2.0 [get_ports {rd_data}]
set_output_delay -clock wr_clk 2.0 [get_ports {full}]
set_output_delay -clock rd_clk 2.0 [get_ports {empty}]
