# Design and Integration Guide

## Architecture

The FIFO stores data in a dual-port memory. The write and read domains maintain independent binary pointers for addressing and Gray pointers for clock-domain crossing.

```text
wr_clk domain                CDC                 rd_clk domain

wr_ptr_bin -> wr_ptr_gray -> 2 FF -> decode -> occupancy/empty
     |                                              |
     +-> memory write                    memory read +-> rd_ptr_bin
     |                                              |
full/almost_full <- decode <- 2 FF <- rd_ptr_gray <-+
```

Only Gray-coded values cross asynchronous domains. Each destination captures them through two registers marked `ASYNC_REG`.

## Reset

`wr_rst_n`, `rd_rst_n`, and `cfg_rst_n` assert state reset asynchronously. Each domain has its own internal two-stage reset synchronizer (`wr_rst_sync`, `rd_rst_sync`, `cfg_rst_sync`) that releases reset on its clock. Requests remain blocked until release completes, and the configuration-domain flops use the synchronized `cfg_reset_n` rather than the raw pad.

Configuration registers reset to:

- almost-empty: `ceil(DEPTH / 5)`
- almost-full: `ceil(4 × DEPTH / 5)`
- active depth: `DEPTH`
- IRQ mask and sticky errors: zero
- flush request/busy state: idle

System integration should normally assert all three resets together. Do not retain FIFO contents across a reset of only one data domain.

## Full and Empty

The read domain declares `empty` when its local read Gray pointer equals the synchronized write Gray pointer.

The write domain decodes the synchronized read pointer and computes occupancy modulo pointer width. `full` asserts when occupancy reaches the configured active depth. Write requests are blocked while `full`; read requests are blocked while `empty`.

## Programmable Status

`almost_full` is generated in the write domain:

```text
write-domain occupancy >= almost-full threshold
```

`almost_empty` is generated in the read domain:

```text
read-domain occupancy <= almost-empty threshold
```

Remote-pointer synchronization adds approximately two destination-clock cycles of status latency. These flags are flow-control warnings, not exact cross-domain counters.

## Configuration Interface

A write occurs on `cfg_clk` when `cfg_we` is high. `cfg_rdata` is combinationally selected while `cfg_re` is high and is zero otherwise.

| Address | Function | Data |
|---:|---|---|
| 0 | Almost-empty threshold | Unsigned entry count |
| 1 | Almost-full threshold | Unsigned entry count |
| 2 | Active-depth selector | Low two bits: full, 75%, 50%, 25%; readback is the cfg-domain synchronized copy |
| 3 | IRQ mask | Bits 0..3 enable full, empty, almost-full, almost-empty |
| 4 | IRQ status | Read-only synchronized level status; same bit assignment as mask |
| 5 | Sticky errors | Bit 0 overflow, bit 1 underflow; write-one-to-clear |
| 6 | Write occupancy | Read-only approximate entry count |
| 7 | Read occupancy | Read-only approximate entry count |
| 8 | Flush | Write bit 0 to request; read bit 0 for busy |
| 9 | Reserved in the core | Reads `0`; the AHB wrapper implements MODE here (see [Bus Wrappers](#bus-wrappers)) |

Thresholds saturate at physical `DEPTH`. Active depth should only change while `empty` is asserted and no read/write request is active. There is no hardware handshake or rejection for an unsafe depth change.

Configuration registers are binary at the external interface, encoded to Gray internally, synchronized into their consuming domains, then decoded. Hold each configuration value stable until the next write. Avoid back-to-back changes faster than both destination domains can observe; Gray encoding guarantees a single-bit transition only between adjacent numeric values, while arbitrary software writes can change multiple Gray bits. For strict atomic arbitrary-value CDC, add a request/acknowledge handshake.

## Interrupts and Errors

`irq` is the OR reduction of IRQ status AND IRQ mask. The four sources are synchronized levels, not edge-latched events. Sticky overflow records a write request while full; sticky underflow records a read request while empty. Sticky errors are separate from the IRQ sources.

Write-one-to-clear is a request/acknowledge toggle handshake: a W1C write flips the request toggle, the destination domain clears the sticky bit when it observes the flip, and flips an acknowledge toggle back. The cfg domain accepts a new clear only when the acknowledge matches the current request, so a clear issued while one is in flight is ignored (not queued). This guarantees that no pair of writes can land entirely between two destination-clock edges and silently lose the clear.

A write request dropped by a flush window can set `overflow_sticky` while `full` is still stale-high, and a read request dropped by a flush window sets `underflow_sticky` (`rd_en` while `empty`). Both are cleared through the normal W1C path.

## Occupancy Readback

Write and read Gray pointers are independently synchronized into `cfg_clk`, decoded, then subtracted modulo pointer width. Addresses 6 and 7 currently expose that same configuration-domain snapshot. The value may lag active traffic and should be used for monitoring, not cycle-exact flow control.

The active-depth readback at address 2 is a cfg-domain synchronized copy of the configured depth (`depth_cfg_sync1/2`), so it also lags the last write by synchronizer latency, like the occupancy registers. The write domain keeps its own synchronized copy for `full`/`almost_full`.

## Flush

Writing bit 0 at address 8 toggles a flush request when no flush is busy. The request crosses independently to both data domains. Each domain resets its local binary/Gray pointer, then holds traffic (`flush_wr_active` / `flush_rd_active`) and delays its acknowledge until the synchronized peer Gray pointer reads zero. Busy remains asserted until both acknowledgements return to `cfg_clk`, so it covers the full resynchronization window — the period in which one domain has already zeroed its pointer while the other still sees the pre-flush value.

While a domain is in its flush window, `do_write`/`do_read` are gated off and `empty` is forced high in the read domain, so no read can be accepted against a stale write pointer (which would advance the read pointer past the write pointer and latch `full` forever). New flush requests while busy are ignored. Stored RAM bits are not scrubbed; pointer reset makes prior entries inaccessible.

## Bus Wrappers

Three optional wrappers sit between a bus and the unchanged core. They are not part
of `async_fifo` and add no logic to it. Common rules: bus data is 32 bits wide (a
push takes the low `DW` bits, a pop returns zero-extended data), configuration
registers are decoded from word offset `[5:2]`, and the core's combinational
`cfg_rdata` is sampled in the same cycle it is selected. A pop always costs one wait
state because the core read data is registered. A push while `full` or a pop while
`empty` stalls the transfer rather than dropping data, and no wrapper returns an
error response.

### APB wrapper

`rtl/fifo_apb_wrapper.sv`. One clock domain: the FIFO write, read, and config
domains all run on `pclk`, so no clock-group constraints are needed beyond the
core's own. `paddr[8]` selects the window (`0` = configuration registers at byte
`0x000..0x03C`, `1` = data window, e.g. `0x100`; lower bits of the data window are
ignored). `rtl/fifo_apb_cfg.sv` is the shared combinational APB-to-`cfg_*` bridge
used by this wrapper and the AHB wrapper.

| Signal | Dir | Clock | Notes |
|---|---|---|---|
| `pclk` | I | — | Sole clock: core write/read/config domains and the APB slave |
| `presetn` | I | — | Reset for all three core domains; async assert, synchronized release |
| `psel`, `penable`, `pwrite` | I | pclk | APB select, enable, direction |
| `paddr[31:0]` | I | pclk | `[8]` window select, `[5:2]` register offset; other bits ignored |
| `pwdata[31:0]` | I | pclk | Push data `[DW-1:0]`, or register write data `[ADDR_W:0]` |
| `prdata[31:0]` | O | pclk | Zero-extended register readback, or the popped word in the completing pop cycle |
| `pready` | O | pclk | `0` while stalled: push while `full`, pop while `empty`, or the pop data cycle |
| `pslverr` | O | pclk | Tied `0` |
| `irq` | O | pclk | OR of masked IRQ status bits |
| `almost_empty` | O | pclk | Core almost-empty flag |
| `almost_full` | O | pclk | Core almost-full flag |
| `wr_ptr_gray_sync[ADDR_W:0]` | O | pclk | Write pointer synchronized into the read domain |
| `rd_ptr_gray_sync[ADDR_W:0]` | O | pclk | Read pointer synchronized into the write domain |

A single APB master owns the bus, so a stalled push/pop cannot be resolved by
another access. Poll IRQ status (register 4) before pushing into a possibly-full
FIFO or popping an empty one.

### AHB wrapper

`rtl/fifo_ahb_wrapper.sv`. Three clock inputs plus two optional raw-side clocks:
`hclk` clocks the AHB engine and every FIFO side the engine owns, `cfg_clk` clocks
the configuration port and the wrapper-local MODE register, and `wr_clk`/`rd_clk`
clock a FIFO side released to external logic by MODE. Treat `hclk` and each of
`wr_clk`/`rd_clk` as an asynchronous pair when the corresponding raw side is used;
`cfg_clk` is asynchronous to `hclk` and to both raw clocks. In MODE 0/3, tie
`wr_clk`/`rd_clk` and `wr_rst_n`/`rd_rst_n` to `hclk`/`hresetn`.

| Signal | Dir | Clock | Notes |
|---|---|---|---|
| `hclk` | I | — | AHB engine and the FIFO side(s) the engine owns |
| `hresetn` | I | — | Resets the AHB engine only (latched request, read capture); not the FIFO |
| `hsel` | I | hclk | Slave select during the address phase |
| `haddr[31:0]` | I | hclk | Ignored: one data window |
| `htrans[1:0]` | I | hclk | `[1]` (NONSEQ/SEQ) starts a transfer; `[0]` ignored |
| `hwrite` | I | hclk | `1` = push, `0` = pop |
| `hsize[2:0]` | I | hclk | Ignored: full 32-bit word transfers only |
| `hwdata[31:0]` | I | hclk | Push data `[DW-1:0]`, sampled in the data phase |
| `hrdata[31:0]` | O | hclk | Zero-extended popped word in the completing data phase; `0` otherwise and for MODE 1 reads |
| `hready` | I | hclk | Global HREADY; tie to `hreadyout` in a single-slave system |
| `hreadyout` | O | hclk | `0` while a data phase waits |
| `hresp` | O | hclk | Tied `0` (OKAY) |
| `cfg_clk` | I | — | Configuration port and MODE register |
| `cfg_presetn` | I | — | Config-domain reset (also the core `cfg_rst_n`) |
| `cfg_psel`, `cfg_penable`, `cfg_pwrite` | I | cfg_clk | APB control |
| `cfg_paddr[31:0]` | I | cfg_clk | `[5:2]` word offset `0..15`; offset `9` is MODE |
| `cfg_pwdata[31:0]` | I | cfg_clk | Register write data; `[1:0]` carries MODE |
| `cfg_prdata[31:0]` | O | cfg_clk | Zero-extended readback, MODE at offset `9` |
| `cfg_pready` | O | cfg_clk | Constant `1` |
| `wr_clk`, `wr_rst_n` | I | wr_clk | Raw write port; drives the core only in MODE 2 |
| `rd_clk`, `rd_rst_n` | I | rd_clk | Raw read port; drives the core only in MODE 1 |
| `ext_wr_en` | I | wr_clk | Raw write enable, used only in MODE 2 |
| `ext_wr_data[DW-1:0]` | I | wr_clk | Raw write data, used only in MODE 2 |
| `ext_rd_en` | I | rd_clk | Raw read enable, used only in MODE 1 |
| `ext_rd_data[DW-1:0]` | O | rd_clk | Registered core read data; meaningful in MODE 1 |
| `full` | O | write | Core full flag; hclk-clocked while the engine owns the write side |
| `empty` | O | read | Core empty flag; hclk-clocked while the engine owns the read side |
| `almost_full`, `almost_empty` | O | write / read | Core threshold flags |
| `irq` | O | cfg_clk | OR of masked IRQ status bits |
| `wr_ptr_gray_sync[ADDR_W:0]` | O | read | Write pointer synchronized into the read domain |
| `rd_ptr_gray_sync[ADDR_W:0]` | O | write | Read pointer synchronized into the write domain |

MODE (configuration offset 9, wrapper-local; the core decodes it as reserved and
reads `0`) selects port ownership:

| MODE | AHB pushes | AHB pops | Raw side released |
|:---:|---|---|---|
| 0 | yes | yes | none |
| 1 | yes | no (reads return `0`) | read side on `rd_clk` |
| 2 | no (writes are accepted with no effect) | yes | write side on `wr_clk` |
| 3 | yes (as 0) | yes (as 0) | none |

The clock muxes are plain combinational muxes with no live-switch protection.
Change MODE only with the affected data-domain reset asserted, the FIFO empty, and
the AHB bus idle: assert `wr_rst_n` and/or `rd_rst_n`, write MODE over the
configuration port, then release. The AHB engine's `full`/`empty` usage is safe
because the side it owns is always the `hclk` side after the mux.

A data phase that cannot complete (push while `full`, pop while `empty`) stretches
`HREADYOUT` indefinitely and stalls the whole AHB bus, so poll IRQ status
(register 4) first. `hresetn` resets only the AHB engine, which abandons such a
latched request without disturbing FIFO contents provided `wr_rst_n`/`rd_rst_n`
stay high. Integrators that tie the FIFO resets to `hresetn` lose the contents.

### AXI-Stream wrapper

`rtl/fifo_axis_wrapper.sv`. Three clock domains: `aclk` (AXI4-Lite config and the
core config port), `s_axis_aclk` (FIFO write side), and `m_axis_aclk` (FIFO read
side). All three are pairwise asynchronous; constrain them as independent clock
groups. No TLAST/TKEEP/TSTRB: the FIFO carries no packet boundaries.

| Signal | Dir | Clock | Notes |
|---|---|---|---|
| `aclk` | I | — | Configuration port |
| `aresetn` | I | — | Config-domain reset |
| `awaddr[31:0]` | I | aclk | `[5:2]` word offset `0..15` |
| `awvalid`, `awready` | I / O | aclk | Address handshake; `awready` low while `aw_pending` or `B` is pending |
| `wdata[31:0]` | I | aclk | Register write data; `[ADDR_W:0]` reaches the core |
| `wvalid`, `wready` | I / O | aclk | Data handshake, independent of `AW` |
| `bresp[1:0]` | O | aclk | Always `OKAY` |
| `bvalid`, `bready` | O / I | aclk | Write response handshake |
| `araddr[31:0]` | I | aclk | `[5:2]` word offset `0..15` |
| `arvalid`, `arready` | I / O | aclk | Read address handshake; one outstanding read |
| `rdata[31:0]` | O | aclk | Zero-extended register readback |
| `rresp[1:0]` | O | aclk | Always `OKAY` |
| `rvalid`, `rready` | O / I | aclk | Read data handshake |
| `s_axis_aclk` | I | — | FIFO write clock |
| `s_axis_aresetn` | I | — | FIFO write-side reset |
| `s_axis_tvalid`, `s_axis_tdata[DW-1:0]` | I | s_axis_aclk | Push request and data |
| `s_axis_tready` | O | s_axis_aclk | `!full`, gated by the synchronized reset release |
| `m_axis_aclk` | I | — | FIFO read clock |
| `m_axis_aresetn` | I | — | FIFO read-side reset |
| `m_axis_tvalid`, `m_axis_tdata[DW-1:0]` | O | m_axis_aclk | Pop result; `tvalid` does not depend on `tready` |
| `m_axis_tready` | I | m_axis_aclk | Sink accept |
| `irq` | O | aclk | OR of masked IRQ status bits |
| `almost_full` | O | write | Core almost-full flag |
| `almost_empty` | O | read | Core almost-empty flag |
| `wr_ptr_gray_sync[ADDR_W:0]` | O | read | Write pointer synchronized into the read domain |
| `rd_ptr_gray_sync[ADDR_W:0]` | O | write | Read pointer synchronized into the write domain |

The `m_axis` output stage is a two-entry pipeline: the core's registered `rd_data`
is stage 1 and a skid register is stage 2, with a bypass path when the skid is
empty. `m_axis_tvalid = s1_full | out_valid` and the data mux selects the skid
first, so the oldest word is always presented and one word per cycle is sustained
while `tready` stays high. With `tready` low the pipeline absorbs two words before
backpressure reaches the FIFO (through `full`), and no word is lost or duplicated.

AXI4-Lite rules: `AW` and `W` are latched independently and executed together, so an
address may be presented before or after its data; exactly one `B` is returned and
held until `BREADY`. Reads accept a single outstanding `AR`, and the register value
is captured on the `AR` handshake cycle (the read address is decoded
combinationally for that access). `arready` also deasserts in a cycle where a
config write executes, so `cfg_addr` always has one driver.

## Parameter Constraints

- `DEPTH` must be a power of two and at least 2 (checked at time 0 with `$fatal`).
- `DEPTH` less than 4 makes the fractional depth modes degenerate (checked with `$warning`).
- `ADDR_W` must equal `$clog2(DEPTH)` (checked at time 0 with `$fatal`).
- Selected fractional depths use integer arithmetic; power-of-two depth makes all four choices integral.

## Verification

The testbenches exercise:

- reset behavior
- fill and drain boundaries
- simultaneous asynchronous traffic
- randomized traffic with scoreboard
- programmable almost thresholds
- configuration saturation and reserved address
- blocked write/read at full/empty
- all four active-depth modes
- IRQ status, masking, and readback
- sticky overflow/underflow detection and W1C clearing
- occupancy and configuration readback
- flush busy handshake, empty result, pointer-status outputs, and post-flush traffic
- flush-resume CDC: reads blocked until the write pointer resyncs (`tb/tb_flush_hazard.sv`)
- APB wrapper: register reset values and readback, reserved offset 9, data-window
  round trip, push-while-full and pop-while-empty wait states, IRQ through the mask
  (`tb/tb_apb_wrapper.sv`)
- AHB wrapper: MODE 0 round trip, write/read wait states with FIFO contents preserved
  across an engine reset, MODE 1 raw read side, MODE 2 raw write side, MODE 3 behaving
  as 0 (`tb/tb_ahb_wrapper.sv`)
- AXI-Stream wrapper: cross-clock 32-word ordering, 50-cycle mid-stream backpressure,
  fill-to-full and drain-to-empty, 10/10-cycle `m_axis_tvalid` throughput, AXI4-Lite
  readback, IRQ (`tb/tb_axis_wrapper.sv`)

Commands:

```bash
make lint
make iverilog
make coverage-report
```

`make coverage-report` runs separate Verilator line and toggle builds. Functional bins are reported by the testbench. Generated coverage files and build products are ignored by Git.

`make iverilog` runs six programs: the main testbench, the flush-hazard regression, the two-FIFO chain, and the three wrapper testbenches. The flush-hazard regression (`tb/tb_flush_hazard.sv`) fixes a 5 MHz / 50 MHz / 500 MHz clock ratio that makes the flush window large enough for the pre-fix wedge to appear. Verilator coverage keeps the main testbench as its single top, so the wrapper and flush-hazard sources are Icarus-only.

Build one wrapper testbench on its own with its exact source list:

```bash
iverilog -g2012 -o sim/tb_apb_wrapper.vvp -I rtl rtl/async_fifo.sv \
  rtl/fifo_apb_cfg.sv rtl/fifo_apb_wrapper.sv tb/tb_apb_wrapper.sv
iverilog -g2012 -o sim/tb_ahb_wrapper.vvp -I rtl rtl/async_fifo.sv \
  rtl/fifo_apb_cfg.sv rtl/fifo_ahb_wrapper.sv tb/tb_ahb_wrapper.sv
iverilog -g2012 -o sim/tb_axis_wrapper.vvp -I rtl rtl/async_fifo.sv \
  rtl/fifo_axis_wrapper.sv tb/tb_axis_wrapper.sv
for v in apb ahb axis; do vvp sim/tb_${v}_wrapper.vvp; done
```

Every wrapper program needs `rtl/async_fifo.sv` plus its own wrapper file; the APB
and AHB programs also need the shared `rtl/fifo_apb_cfg.sv` bridge. The `sim/*.vvp`
outputs are git-ignored.

The `FORMAL` assertions are simulation/formal-only. Icarus parses them but does not implement concurrent assertions, so use `iverilog -g2012 -gsupported-assertions -DFORMAL` to syntax-check that variant; Verilator accepts it under `--assert`.

## Synthesis and Timing

- Preserve the two-stage synchronizers and reset synchronizers.
- Apply asynchronous clock-group constraints between `wr_clk`, `rd_clk`, and `cfg_clk`.
- Review `fpga/constraints.sdc`; adapt object paths to the synthesis tool.
- Constrain Gray buses for skew where supported, so source bits cannot arrive more than one fast-clock period apart.
- Confirm dual-port memory inference in synthesis reports.
- See [Wrapper clock domains](#wrapper-clock-domains) for the wrapper clock sets, group declarations, and reset mapping.

### Wrapper clock domains

The wrappers add no CDC logic of their own. Every cross-domain path is still one of
the core's two-stage synchronizers, plus one quasi-static control path in the AHB
wrapper (MODE).

| Wrapper | Clocks | SDC grouping | Cross-domain paths |
|---|---|---|---|
| APB | `pclk` | single clock, no groups needed | none; the core's write, read, and config domains share `pclk`, so its synchronizers become same-clock registers and keep their two-cycle latency |
| AHB | `hclk`, `cfg_clk`, `wr_clk`, `rd_clk` | one `-asynchronous` set over all four | core pointer synchronizers between the AHB-owned side (`hclk`) and the released raw side (`wr_clk` or `rd_clk`); config Gray synchronizers from `cfg_clk` into each data domain; MODE (`cfg_clk`) to the clock muxes and port-ownership gates per MODE |
| AXI-Stream | `aclk`, `s_axis_aclk`, `m_axis_aclk` | one `-asynchronous` set over all three | core pointer synchronizers (`s_axis_aclk` ↔ `m_axis_aclk`) and config synchronizers from `aclk` into both data domains; no wrapper register crosses a domain |

- Declare the whole clock set asynchronous even when a mode leaves a raw clock idle.
  The AHB engine's combinational gating still touches the flag of the side it does
  not own, and the MODE muxes expose both clocks at the core's clock pins, so
  pairwise-in-use groups would leave real, statically disabled paths unconstrained.
- AHB status and pointer outputs change owning clock with MODE. In MODE 0/3 all of
  `full`, `empty`, `almost_full`, `almost_empty`, `wr_ptr_gray_sync`, and
  `rd_ptr_gray_sync` are `hclk`-domain; in MODE 1 `empty`, `almost_empty`, and
  `wr_ptr_gray_sync` are `rd_clk`; in MODE 2 `full`, `almost_full`, and
  `rd_ptr_gray_sync` are `wr_clk`. Constrain each for the mode you configure; the
  commented templates in `fpga/constraints.sdc` encode this.
- Treat the AHB MODE clock muxes as quasi-static: they are plain combinational
  muxes, so nothing retimes across them and a live switch is unsupported. The MODE
  register is written from `cfg_clk` only with the data-domain resets asserted, so
  no path needs to close from it to the mux selects; false-path it if a tool
  reports one (example in the SDC).
- The AXI-Stream output pipeline (`s1_full`, `out_valid`, `out_data`) and
  `pop_issue` are entirely `m_axis_aclk`; `s_axis_tready` and `wr_en` are entirely
  `s_axis_aclk` and depend combinationally on the core's `full`. Keep the ready
  path in the write domain; do not pipeline it into the read domain.
- The wrappers add no new Gray buses, so the skew rule above is unchanged, and the
  pointer outputs they expose are already the core's two-stage synchronized copies.
- Reset mapping: APB `presetn` covers all three core domains; AHB `hresetn` resets
  the AHB engine only, with `cfg_presetn` for config and `wr_rst_n`/`rd_rst_n` for
  the raw sides; AXI-Stream uses `aresetn`, `s_axis_aresetn`, and `m_axis_aresetn`
  for config, write, and read. Each is asynchronous-assert with a per-domain
  synchronized release, so false-path each reset port.
