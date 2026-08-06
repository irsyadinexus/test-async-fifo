# Configurable Async FIFO

Synthesizable SystemVerilog asynchronous FIFO with independent write/read clocks, Gray-code CDC, programmable warning thresholds, and selectable active depth.

## Features

- Independent `wr_clk` and `rd_clk`
- Gray-coded pointers with two-stage synchronizers
- Asynchronous reset assertion, synchronous release per clock domain
- Registered read output; dual-port RAM inference
- Programmable `almost_empty` and `almost_full`
- Runtime active depth: 100%, 75%, 50%, or 25% of `DEPTH`
- Gray-encoded configuration CDC
- Directed, randomized, boundary, and coverage tests

## Quick Start

Requirements: Icarus Verilog and/or Verilator.

```bash
make lint       # RTL lint
make iverilog   # functional simulation
make sim        # Verilator simulation + combined coverage data
make coverage-report  # separate line/toggle reports
```

Latest verified results (`DW=8`, `DEPTH=16`):

- Functional tests: all passed, 0 errors
- Depth modes: 4/4
- Almost-flag transitions: 4/4
- Boundary cases: 4/4
- Line coverage: 97.8% (315/322)
- Toggle coverage: 89.3% (50/56)

## Parameters

| Parameter | Default | Description |
|---|---:|---|
| `DW` | 8 | Data width |
| `DEPTH` | 16 | Physical FIFO depth; power of two |
| `ADDR_W` | `$clog2(DEPTH)` | Address width |

## Ports

| Signal | Dir | Domain | Description |
|---|---|---|---|
| `wr_clk` | I | write | Write clock |
| `wr_rst_n` | I | write | Active-low; async assert, synchronized release |
| `wr_en` | I | write | Write request; ignored when `full` |
| `wr_data[DW-1:0]` | I | write | Write data |
| `full` | O | write | Active-depth limit reached |
| `almost_full` | O | write | Occupancy at/above configured threshold |
| `rd_clk` | I | read | Read clock |
| `rd_rst_n` | I | read | Active-low; async assert, synchronized release |
| `rd_en` | I | read | Read request; ignored when `empty` |
| `rd_data[DW-1:0]` | O | read | Registered read data |
| `empty` | O | read | No readable entries |
| `almost_empty` | O | read | Occupancy at/below configured threshold |
| `cfg_clk` | I | config | Configuration clock |
| `cfg_rst_n` | I | config | Active-low configuration reset |
| `cfg_we` | I | config | Configuration write enable |
| `cfg_addr[1:0]` | I | config | Register address |
| `cfg_wdata[ADDR_W:0]` | I | config | Register write data |
| `wr_ptr_gray_sync[ADDR_W:0]` | O | read | Write pointer synchronized into read domain |
| `rd_ptr_gray_sync[ADDR_W:0]` | O | write | Read pointer synchronized into write domain |

## Configuration Registers

| `cfg_addr` | Register | Reset | Write value |
|---:|---|---:|---|
| `0` | Almost-empty threshold | `ceil(20% × DEPTH)` | Entry count; values above `DEPTH` saturate |
| `1` | Almost-full threshold | `ceil(80% × DEPTH)` | Entry count; values above `DEPTH` saturate |
| `2` | Active depth | 100% | `cfg_wdata[1:0]`: `0`=100%, `1`=75%, `2`=50%, `3`=25% |
| `3` | Reserved | — | Ignored |

Change active depth only while the FIFO is empty. Software must ensure the almost-full threshold is sensible for the selected active depth.

Configuration values are converted to Gray code in `cfg_clk`, synchronized through two registers, then decoded in the destination domain. See [doc/design.md](doc/design.md) for CDC assumptions and integration constraints.

## Repository Layout

```text
rtl/async_fifo.sv       FIFO RTL
rtl/async_fifo_if.sv    Optional SystemVerilog interface
rtl/async_fifo_pkg.sv   Shared helpers/types
tb/tb_async_fifo.sv     Self-checking testbench
sim/run_iverilog.sh     Icarus runner
sim/run_verilator.sh    Verilator coverage runner
sim/sim_main.cpp        Verilator coverage harness
sim/coverage_report.py  Line/toggle summary
fpga/constraints.sdc    Example CDC constraints
doc/design.md           Design and integration details
```

## Notes

- `rd_data` updates on an accepted read clock edge.
- Status uses synchronized remote pointers; cross-domain occupancy is intentionally approximate by synchronizer latency.
- Apply CDC timing constraints and preserve `ASYNC_REG` chains in implementation.
- No license file currently exists; add one before redistribution if required.

## References

- C. E. Cummings, “Simulation and Synthesis Techniques for Asynchronous FIFO Design,” SNUG 2002.
- C. E. Cummings, “Synthesis and Scripting Techniques for Designing Multi-Asynchronous Clock Designs,” SNUG 2002.
