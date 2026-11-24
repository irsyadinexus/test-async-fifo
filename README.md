# Configurable Async FIFO

Synthesizable SystemVerilog asynchronous FIFO with independent write, read, and configuration clocks, Gray-code CDC, programmable warning thresholds, and selectable active depth.

## Features

- Independent `wr_clk`, `rd_clk`, and `cfg_clk` (any frequency relationship)
- Gray-coded pointers with two-stage synchronizers
- Asynchronous reset assertion, synchronous release per clock domain
- Registered read output; dual-port RAM inference
- Programmable `almost_empty` and `almost_full`
- Runtime active depth: 100%, 75%, 50%, or 25% of `DEPTH`
- Gray-encoded configuration CDC
- Maskable level interrupt for full, empty, almost-full, and almost-empty
- Sticky overflow/underflow status with acknowledged write-one-to-clear
- Configuration and approximate occupancy readback
- Cross-domain flush command with busy handshake and pointer-resynchronization gating
- Directed, randomized, boundary, and coverage tests
- Dedicated flush-resume CDC regression (`tb/tb_flush_hazard.sv`)
- Two-FIFO controller-chain simulation with a dedicated clock per port (`tb/tb_two_fifo.sv`)
- APB, AHB-Lite, and AXI-Stream/AXI4-Lite bus wrappers around the unchanged core,
  sharing a combinational `fifo_apb_cfg` register bridge
- Dedicated wrapper testbenches with wait-state, MODE-switch, and backpressure checks

## Quick Start

Requirements: Icarus Verilog and/or Verilator. `make sim` and the coverage targets
additionally need `verilator_coverage` on `PATH`; some Verilator packages (for
example the conda-forge build) do not install it, in which case the simulation
passes and only the trailing coverage-report step fails.

```bash
make lint            # RTL lint
make iverilog        # functional + flush-hazard + two-FIFO + 3 wrapper TBs (Icarus)
make two-fifo        # two-FIFO controller-chain simulation (DEPTH=64) only
make sim             # Verilator simulation + combined coverage data
make coverage-report # separate line/toggle reports
```

Latest verified results (commit `ff8ada2`, 2026-11-24). Functional tests use
`DW=8`, `DEPTH=16`, wr 100 MHz / rd 62.5 MHz / cfg 166.7 MHz:

- Functional tests: all passed, 0 errors; 334 writes and 282 reads modeled and checked
- Flush-resume regression (wr 5 MHz / rd 50 MHz / cfg 500 MHz): passed
- Two-FIFO chain (`DEPTH=64`, 64-word bursts; ctl 100 MHz, f1w 13 MHz,
  f1r 9 MHz, f2w 7 MHz, f2r 11 MHz; 100 ctl cycles between bursts): passed,
  0 errors; 512 transfers total (128 writes and 128 reads per FIFO), 256 read
  words compared, ~65 µs of simulated time; waveform in `sim/tb_two_fifo.vcd`
- Wrapper testbenches (`make iverilog`; APB `pclk` 100 MHz, AHB `hclk` 100 /
  `cfg_clk` 71.4 / ext `wr_clk` 25 / ext `rd_clk` 38.5 MHz, AXI-Stream `aclk` 83.3 /
  `s_axis_aclk` 100 / `m_axis_aclk` 71.4 MHz): APB 36 pushes / 36 pops, AHB 30
  writes / 29 reads, AXI-Stream 15 words in / 15 out, all 0 errors; the APB and AHB
  stall probes held `PREADY`/`HREADYOUT` low for 7 cycles before the test aborted the
  transfer, every pop adds exactly one wait state, and AXI-Stream `m_axis_tvalid` was
  high in 10/10 consecutive cycles with `tready` held high
- `make lint`: no errors for `async_fifo` and the four wrapper RTL files; the only
  warnings are `UNUSEDSIGNAL` on intentionally unused bus bits and the core's
  pre-existing `SYNCASYNCNET`, both tolerated by `-Wno-fatal`
- Depth modes: 4/4
- Almost-flag transitions: 4/4
- Boundary cases: 4/4

The coverage and FORMAL figures below predate the wrappers and were not re-measured
here: `sim/run_verilator.sh` compiles only `rtl/async_fifo.sv` and
`tb/tb_async_fifo.sv`, so the wrappers cannot change them, and `verilator_coverage`
is not installed in this environment.

- Line coverage: 613/616 (99.5%) over RTL + testbench; the only uncovered RTL line is
  the `DEPTH < 4` parameter warning
- Toggle coverage: 81/81 (100.0%)
- FORMAL variant (`iverilog -g2012 -gsupported-assertions -DFORMAL`) compiles clean

## Parameters

| Parameter | Default | Description |
|---|---:|---|
| `DW` | 8 | Data width |
| `DEPTH` | 16 | Physical FIFO depth; power of two, at least 2 |
| `ADDR_W` | `$clog2(DEPTH)` | Address width; must equal `$clog2(DEPTH)` |

Checks run at time 0: a non-power-of-two or `DEPTH < 2` fails elaboration with
`$fatal`, a mismatched `ADDR_W` fails with `$fatal`, and `DEPTH < 4` warns because
the 25% depth mode then degenerates.

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
| `cfg_rst_n` | I | config | Active-low; async assert, synchronized release |
| `cfg_we` | I | config | Configuration write enable |
| `cfg_re` | I | config | Configuration read enable; gates `cfg_rdata` |
| `cfg_addr[3:0]` | I | config | Register address |
| `cfg_wdata[ADDR_W:0]` | I | config | Register write data |
| `cfg_rdata[ADDR_W:0]` | O | config | Combinational register read data; zero when `cfg_re=0` |
| `irq` | O | config | OR of enabled interrupt status bits |
| `wr_ptr_gray_sync[ADDR_W:0]` | O | read | Write pointer synchronized into read domain |
| `rd_ptr_gray_sync[ADDR_W:0]` | O | write | Read pointer synchronized into write domain |

## Configuration Registers

| Address | Register | Access | Reset | Data |
|---:|---|---|---:|---|
| `0` | Almost-empty threshold | R/W | `ceil(20% × DEPTH)` | Entry count; writes above `DEPTH` saturate |
| `1` | Almost-full threshold | R/W | `ceil(80% × DEPTH)` | Entry count; writes above `DEPTH` saturate |
| `2` | Active depth | R/W | `DEPTH` | Write selector `[1:0]`: `0`=100%, `1`=75%, `2`=50%, `3`=25%; read returns the entry count from a `cfg_clk`-synchronized copy |
| `3` | IRQ mask | R/W | `0` | `[0]` full, `[1]` empty, `[2]` almost-full, `[3]` almost-empty; `1` enables source |
| `4` | IRQ status | R | dynamic | Bit assignment matches IRQ mask |
| `5` | Sticky errors | R/W1C | `0` | `[0]` overflow, `[1]` underflow; write `1` to clear; ignored until the previous clear is acknowledged |
| `6` | Write occupancy | R | `0` | Approximate entry count sampled in `cfg_clk` |
| `7` | Read occupancy | R | `0` | Approximate entry count sampled in `cfg_clk` |
| `8` | Flush control/status | R/W | `0` | Write `[0]=1` to request flush; read `[0]` as busy |
| `9` | MODE (AHB wrapper only) | R/W | `0` | Wrapper-local, not implemented in the core (reads `0` there): `0` = AHB pushes and pops, `1` = AHB pushes with the raw read port on `rd_clk`, `2` = AHB pops with the raw write port on `wr_clk`, `3` = reserved, behaves as `0` |

`irq = |(irq_status & irq_mask)`. Status sources are synchronized levels, so assertion/deassertion has CDC latency. Sticky errors do not currently feed `irq`.

Flush resets both data-domain pointers through a request/acknowledge toggle handshake. Each domain resets its pointer, holds traffic, and only then acknowledges; the acknowledge is delayed until the synchronized peer pointer reads zero, so `flush_busy` covers the whole resynchronization window. A write or read request issued during that window is dropped and sets the corresponding sticky overflow/underflow bit (clear it through address `5`). Do not issue another flush while busy; such writes are ignored. FIFO memory is not erased, but flushed entries become inaccessible.

Sticky clear is a toggle request/acknowledge handshake as well. A W1C write issued while a previous clear is still in flight (acknowledge not yet returned) is ignored rather than queued, so back-to-back writes cannot drop or wedge a clear. Poll address `5` and retry if needed.

A request dropped by a flush window can also set a sticky bit that no real data error caused: a dropped write sets overflow while `full` is still stale-high, and a dropped read always sets underflow because `empty` is forced during the window. Read address `5` and clear it through the same W1C path before treating the FIFO as error-free.

Change active depth only while the FIFO is empty. Software must ensure the almost-full threshold is sensible for the selected active depth.

Change MODE only while the affected data-domain reset is asserted: assert `wr_rst_n` and/or `rd_rst_n`, write MODE through the AHB wrapper's APB port, then release. The wrapper clock muxes are plain combinational muxes with no live-switch protection, so a mode change with running data clocks is not supported. Switch with the FIFO empty and the AHB bus idle.

Configuration values are converted to Gray code in `cfg_clk`, synchronized through two registers, then decoded in the destination domain. See [doc/design.md](doc/design.md) for CDC assumptions and integration constraints.

## Bus Wrappers

Three wrappers drive the unchanged core. Bus data is 32 bits wide: a push takes the
low `DW` bits of the write data, and a pop returns zero-extended data. Configuration
registers are decoded from word offset `[5:2]`. A pop always costs one wait state
because the core read data is registered. A push while `full` or a pop while `empty`
stalls the transfer (no error response) rather than dropping data; since these
wrappers own the only path that could free space, software must poll IRQ status
(register `4`) before a transfer that could stall.

| Wrapper | File | Data interface | Config interface | Clocking |
|---|---|---|---|---|
| APB | `rtl/fifo_apb_wrapper.sv` | one APB slave, `paddr[8]=0` register window (`0x000`–`0x03C`), `paddr[8]=1` data window (`0x100`): write = push, read = pop | same port, register window | whole core on `pclk` |
| AHB | `rtl/fifo_ahb_wrapper.sv` | AHB-Lite slave, single data window: write = push, read = pop | separate APB slave | `hclk` for the AHB side, `cfg_clk` for config, `wr_clk`/`rd_clk` for a raw side released by MODE |
| AXI-Stream | `rtl/fifo_axis_wrapper.sv` | `s_axis` (push) and `m_axis` (pop), independent clocks | AXI4-Lite slave on `aclk` | `s_axis_aclk`, `m_axis_aclk`, `aclk` |

All three wrappers take the core's `DW` and `DEPTH` (with `ADDR_W = $clog2(DEPTH)`)
and are verified at `DW=8`, `DEPTH=16`. Their bus data ports are fixed at 32 bits;
making a bus as narrow as `DW` is a port-list edit, not a parameter.

`rtl/fifo_apb_cfg.sv` is the shared, purely combinational APB-to-`cfg_*` bridge: one
cycle access phase, `PREADY` constant `1`, all 16 word offsets forwarded, and the
core ignores reserved offsets through its existing `default:` arm.

APB and AHB wrappers: a data-window push completes in the single access/data phase
while `!full`; a pop issues `rd_en`, holds `PREADY`/`HREADYOUT` low for one cycle,
then returns the popped word. In MODE 0 the AHB engine owns both FIFO ports; in MODE
1 the raw read port is exposed on `rd_clk` and AHB reads complete with zero data
without popping; in MODE 2 the raw write port is exposed on `wr_clk` and AHB writes
complete without pushing. The AHB engine relies on `full`/`empty` always coming from
the side it currently owns, which the MODE mux guarantees.

`hresetn` resets only the AHB engine (latched request and read-capture state), not the
FIFO: a permanently stalled data phase is abandoned by asserting `hresetn`, and FIFO
contents survive as long as `wr_rst_n`/`rd_rst_n` stay high. A single-slave system ties
`hready` to `hreadyout`. `haddr`, `hsize`, and `htrans[0]` are ignored; only
`HTRANS[1]` (NONSEQ/SEQ) starts a transfer, and every transfer is a full 32-bit word.

AXI-Stream wrapper: `s_axis_tready = !full`, `wr_en = tvalid && tready`. The `m_axis`
side is a two-entry output pipeline — the core's registered `rd_data` as stage 1 and a
skid register as stage 2 — with a direct bypass, so `m_axis_tvalid` stays high on
consecutive cycles while `tready` is high and backpressure never loses or duplicates a
word. There is no TLAST/TKEEP/TSTRB: the FIFO carries no packet boundaries.

AXI4-Lite writes latch `AW` and `W` independently and execute once both are present;
`B` is held until `BREADY`. Reads accept one outstanding `AR`, return the
combinational register value registered into `RDATA`, and hold `RVALID` until
`RREADY`. Both responses are always `OKAY`; reserved offsets are forwarded and
ignored.

### APB wrapper ports

`fifo_apb_wrapper`: one APB slave, `ADDR_W = $clog2(DEPTH)`. The FIFO write, read,
and config domains all run on `pclk`, so the domain column below names the core
domain rather than a second clock.

| Signal | Dir | Domain | Description |
|---|---|---|---|
| `pclk` | I | — | Single clock: FIFO write/read/config and the APB slave |
| `presetn` | I | — | Active-low reset for all three core domains; async assert, synchronized release |
| `psel`, `penable`, `pwrite` | I | pclk | APB select, enable, direction (`1` = write) |
| `paddr[31:0]` | I | pclk | `[8]` selects the window (`0` = registers, `1` = data), `[5:2]` is the register offset |
| `pwdata[31:0]` | I | pclk | Push data `[DW-1:0]`, or register write data `[ADDR_W:0]` |
| `prdata[31:0]` | O | pclk | Zero-extended register readback, or the popped word during the completing pop cycle; `0` otherwise |
| `pready` | O | pclk | `0` while the access waits: push while `full`, pop while `empty`, or the pop's data cycle; `1` for every register access |
| `pslverr` | O | pclk | Tied `0`; an unsatisfiable access stalls instead of erroring |
| `irq` | O | config | Core IRQ, OR of the masked status bits |
| `almost_empty` | O | read | Core almost-empty threshold flag |
| `almost_full` | O | write | Core almost-full threshold flag |
| `wr_ptr_gray_sync[ADDR_W:0]` | O | read | Write pointer synchronized into the read domain |
| `rd_ptr_gray_sync[ADDR_W:0]` | O | write | Read pointer synchronized into the write domain |

### AHB wrapper ports

`fifo_ahb_wrapper`: AHB-Lite data slave, APB config slave, and the raw FIFO side.

| Signal | Dir | Domain | Description |
|---|---|---|---|
| `hclk` | I | — | AHB clock; also the FIFO clock for every side the AHB engine owns |
| `hresetn` | I | — | Resets the AHB engine only (latched request, read capture), not the FIFO |
| `hsel` | I | hclk | Slave select during the address phase |
| `haddr[31:0]` | I | hclk | Ignored: one data window |
| `htrans[1:0]` | I | hclk | `[1]` (NONSEQ/SEQ) starts a transfer; `[0]` ignored |
| `hwrite` | I | hclk | `1` = push, `0` = pop |
| `hsize[2:0]` | I | hclk | Ignored: every transfer is a full 32-bit word |
| `hwdata[31:0]` | I | hclk | Push data `[DW-1:0]`, sampled in the data phase |
| `hrdata[31:0]` | O | hclk | Zero-extended popped word in the completing data phase; `0` otherwise, and `0` for MODE 1 reads |
| `hready` | I | hclk | Global HREADY from the interconnect; tie to `hreadyout` in a single-slave system |
| `hreadyout` | O | hclk | `0` while a data phase waits (push/`full`, pop/`empty`, or the pop's data cycle) |
| `hresp` | O | hclk | Tied `0` (OKAY); the slave stalls instead of erroring |
| `cfg_clk` | I | — | Config clock: the MODE register and the core config port |
| `cfg_presetn` | I | — | Active-low config-domain reset (also the core `cfg_rst_n`) |
| `cfg_psel`, `cfg_penable`, `cfg_pwrite` | I | cfg_clk | APB select, enable, direction |
| `cfg_paddr[31:0]` | I | cfg_clk | `[5:2]` word offset `0..15`; offset `9` is the wrapper MODE register |
| `cfg_pwdata[31:0]` | I | cfg_clk | Register write data; `[ADDR_W:0]` reaches the core, `[1:0]` carries MODE |
| `cfg_prdata[31:0]` | O | cfg_clk | Zero-extended register readback, including MODE at offset `9` |
| `cfg_pready` | O | cfg_clk | Constant `1`: zero-wait-state config accesses |
| `wr_clk`, `wr_rst_n` | I | write | FIFO write-side clock/reset, driving the core only in MODE 2; tie the reset to `hresetn` in MODE 0/3 |
| `rd_clk`, `rd_rst_n` | I | read | FIFO read-side clock/reset, driving the core only in MODE 1; tie the reset to `hresetn` in MODE 0/3 |
| `ext_wr_en` | I | write | Raw write enable; reaches the FIFO only in MODE 2 |
| `ext_wr_data[DW-1:0]` | I | write | Raw write data; used only in MODE 2 |
| `ext_rd_en` | I | read | Raw read enable; reaches the FIFO only in MODE 1 |
| `ext_rd_data[DW-1:0]` | O | read | Registered core read data; meaningful in MODE 1 |
| `full` | O | write | Core full flag (hclk-clocked whenever the AHB owns the write side) |
| `empty` | O | read | Core empty flag (hclk-clocked whenever the AHB owns the read side) |
| `almost_full`, `almost_empty` | O | write / read | Core threshold flags |
| `irq` | O | config | Core IRQ, OR of the masked status bits |
| `wr_ptr_gray_sync[ADDR_W:0]` | O | read | Write pointer synchronized into the read domain |
| `rd_ptr_gray_sync[ADDR_W:0]` | O | write | Read pointer synchronized into the write domain |

### AXI-Stream wrapper ports

`fifo_axis_wrapper`: AXI4-Lite config slave, `s_axis` push side, `m_axis` pop side.

| Signal | Dir | Domain | Description |
|---|---|---|---|
| `aclk` | I | — | Config clock (core `cfg_clk`) |
| `aresetn` | I | — | Active-low config-domain reset |
| `awaddr[31:0]` | I | aclk | `[5:2]` word offset `0..15` |
| `awvalid`, `awready` | I / O | aclk | Write address handshake; `awready` is `0` while a `B` response or a latched address is pending |
| `wdata[31:0]` | I | aclk | Register write data; `[ADDR_W:0]` reaches the core |
| `wvalid`, `wready` | I / O | aclk | Write data handshake, independent of `AW` |
| `bresp[1:0]` | O | aclk | Always `OKAY` |
| `bvalid`, `bready` | O / I | aclk | Write response handshake; `bvalid` holds until `bready` |
| `araddr[31:0]` | I | aclk | `[5:2]` word offset `0..15` |
| `arvalid`, `arready` | I / O | aclk | Read address handshake; one outstanding read, `arready` low while an `R` response is pending or a config write executes |
| `rdata[31:0]` | O | aclk | Zero-extended register readback |
| `rresp[1:0]` | O | aclk | Always `OKAY` |
| `rvalid`, `rready` | O / I | aclk | Read data handshake; `rvalid` holds until `rready` |
| `s_axis_aclk` | I | — | FIFO write clock |
| `s_axis_aresetn` | I | — | Active-low FIFO write-side reset |
| `s_axis_tvalid`, `s_axis_tdata[DW-1:0]` | I | write | Push request and data |
| `s_axis_tready` | O | write | `!full`, gated by the synchronized reset release |
| `m_axis_aclk` | I | — | FIFO read clock |
| `m_axis_aresetn` | I | — | Active-low FIFO read-side reset |
| `m_axis_tvalid`, `m_axis_tdata[DW-1:0]` | O | read | Pop result; `tvalid` never waits on `tready` |
| `m_axis_tready` | I | read | Sink accept; `0` fills the two-entry output pipeline, then applies backpressure to the FIFO |
| `irq` | O | config | Core IRQ, OR of the masked status bits |
| `almost_full` | O | write | Core almost-full threshold flag |
| `almost_empty` | O | read | Core almost-empty threshold flag |
| `wr_ptr_gray_sync[ADDR_W:0]` | O | read | Write pointer synchronized into the read domain |
| `rd_ptr_gray_sync[ADDR_W:0]` | O | write | Read pointer synchronized into the write domain |

## Two-FIFO Chain Simulation

`tb/tb_two_fifo.sv` (`make two-fifo`) instantiates two `async_fifo` DUTs and one
behavioral controller. Every FIFO port runs on its own clock, so both DUTs' Gray
CDC is exercised. Each FIFO is accessed in back-to-back bursts: every word in a
burst is transferred on consecutive target-port cycles, and the controller waits
100 `ctl_clk` cycles (1 µs at 100 MHz) between a completed burst of writes and the
following burst of reads, or a completed burst of reads and the following burst
of writes.

```mermaid
flowchart LR
    C["Controller<br/>ctl_clk 10 ns (100 MHz)<br/>100 ctl cycles between bursts"]
    F1["FIFO1 — async_fifo, DEPTH=64<br/>wr f1w 76.9 ns (13 MHz), rd f1r 111.1 ns (9 MHz)"]
    F2["FIFO2 — async_fifo, DEPTH=64<br/>wr f2w 142.9 ns (7 MHz), rd f2r 90.9 ns (11 MHz)"]
    C -->|"write: phases 1, 5"| F1
    F1 -->|"read: phases 2, 6"| C
    C -->|"write: phases 2, 4"| F2
    F2 -->|"read: phases 3, 5"| C
```

Phase 1 fills FIFO1 with random words, phase 2 drains FIFO1 into the controller's
move buffer and refills FIFO2 from it, phase 3 reads FIFO2 back. Phase 4 fills
FIFO2 with ascending words, phase 5 drains FIFO2 into the buffer and refills
FIFO1, phase 6 reads FIFO1 back. Every read word is compared against the
`exp1`/`exp2` expected-data queues; phase 7 checks both DUTs are empty with
balanced pointers. The run dumps full-depth waveforms to `sim/tb_two_fifo.vcd`.
Measured from that dump: bursts of 64 accesses spaced exactly one port clock
(f1w 76.92 ns, f1r 111.11 ns, f2w 142.86 ns, f2r 90.91 ns), burst boundaries
≥ 1.1 µs apart.

## Verification

Six Icarus programs plus the Verilator flow. Every program is self-checking: it
compares against queues or scoreboards, counts errors, and carries a timeout
watchdog that reports `TIMEOUT`. The functional and wrapper programs end with
`*** ALL TESTS PASSED ***` (or `*** TESTS FAILED ***`) plus an `Errors:` total; the
two dedicated regressions print `*** FLUSH HAZARD TEST PASSED ***` and
`*** TWO-FIFO CHAIN TEST PASSED ***`.

| Testbench | Covers |
|---|---|
| `tb/tb_async_fifo.sv` | reset, fill/drain boundaries, simultaneous asynchronous traffic, randomized traffic against a scoreboard, programmable thresholds, all four depth modes, IRQ status and mask, sticky errors and W1C, occupancy and configuration readback, flush handshake |
| `tb/tb_flush_hazard.sv` | flush-resume CDC wedge at a 5 MHz / 50 MHz / 500 MHz clock ratio |
| `tb/tb_two_fifo.sv` | two FIFOs with a dedicated clock per port, burst chains with 100-cycle gaps, expected-data queues |
| `tb/tb_apb_wrapper.sv` | register reset values and readback, reserved offset 9, data-window round trip, push-while-full and pop-while-empty wait states, IRQ through the mask |
| `tb/tb_ahb_wrapper.sv` | MODE 0 round trip, write/read wait states with FIFO contents preserved across an engine reset, MODE 1 raw read side, MODE 2 raw write side, MODE 3 behaving as 0 |
| `tb/tb_axis_wrapper.sv` | cross-clock 32-word ordering, 50-cycle mid-stream backpressure, fill-to-full and drain-to-empty, 10/10-cycle `m_axis_tvalid` throughput, AXI4-Lite readback, IRQ |

`make iverilog` runs all six; `make sim` builds only `tb/tb_async_fifo.sv` under
Verilator, with coverage. Measured results are in [Quick Start](#quick-start).

The wrapper testbenches run at `DW=8`, `DEPTH=16` and can be built individually:

```bash
# APB: register window + data window
iverilog -g2012 -o sim/tb_apb_wrapper.vvp -I rtl rtl/async_fifo.sv \
  rtl/fifo_apb_cfg.sv rtl/fifo_apb_wrapper.sv tb/tb_apb_wrapper.sv
# AHB: AHB-Lite data slave + APB config port + MODE 1/2/3
iverilog -g2012 -o sim/tb_ahb_wrapper.vvp -I rtl rtl/async_fifo.sv \
  rtl/fifo_apb_cfg.sv rtl/fifo_ahb_wrapper.sv tb/tb_ahb_wrapper.sv
# AXI-Stream: s_axis/m_axis + AXI4-Lite config
iverilog -g2012 -o sim/tb_axis_wrapper.vvp -I rtl rtl/async_fifo.sv \
  rtl/fifo_axis_wrapper.sv tb/tb_axis_wrapper.sv
vvp sim/tb_apb_wrapper.vvp     # same for tb_ahb_wrapper / tb_axis_wrapper
```

A wrapper test at a stall (push while `full`, pop while `empty`) is abandoned at
test level: the APB and AXI-Stream testbenches deassert `PSEL`/`TVALID`, and the AHB
testbench pulses `hresetn`, which resets only the AHB engine so the FIFO contents
survive the abort. See [Bus Wrappers](#bus-wrappers) for the software rule these
tests are working around.

## Repository Layout

```text
rtl/async_fifo.sv        FIFO RTL
rtl/fifo_apb_cfg.sv      Combinational APB-to-cfg register bridge
rtl/fifo_apb_wrapper.sv  APB slave wrapper (register window + data window)
rtl/fifo_ahb_wrapper.sv  AHB-Lite data slave + APB config port + MODE muxing
rtl/fifo_axis_wrapper.sv AXI-Stream (s_axis/m_axis) + AXI4-Lite config slave
tb/tb_async_fifo.sv      Self-checking testbench
tb/tb_flush_hazard.sv    Flush-resume CDC regression
tb/tb_two_fifo.sv        Two-FIFO controller-chain simulation
tb/tb_apb_wrapper.sv     APB wrapper testbench
tb/tb_ahb_wrapper.sv     AHB wrapper testbench (includes MODE 1/2/3)
tb/tb_axis_wrapper.sv    AXI-Stream wrapper testbench
sim/run_iverilog.sh      Icarus runner
sim/run_verilator.sh     Verilator coverage runner
sim/sim_main.cpp         Verilator coverage harness
sim/coverage_report.py   Line/toggle summary
fpga/constraints.sdc     Example CDC constraints
doc/design.md            Design and integration details
```

## Notes

- `rd_data` updates on an accepted read clock edge.
- Status, occupancy, and active-depth readback use synchronized pointers/signals; all are intentionally approximate by synchronizer latency.
- Apply CDC timing constraints and preserve `ASYNC_REG` chains in implementation.
- Coverage reporting needs `verilator_coverage` on `PATH`; it is not part of every Verilator package.
- No license file currently exists; add one before redistribution if required.

## References

- C. E. Cummings, “Simulation and Synthesis Techniques for Asynchronous FIFO Design,” SNUG 2002.
- C. E. Cummings, “Synthesis and Scripting Techniques for Designing Multi-Asynchronous Clock Designs,” SNUG 2002.
