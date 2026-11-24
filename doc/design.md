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

## Parameter Constraints

- `DEPTH` must be a power of two and at least 2 (checked at time 0 with `$fatal`).
- `DEPTH` less than 4 makes the fractional depth modes degenerate (checked with `$warning`).
- `ADDR_W` must equal `$clog2(DEPTH)` (checked at time 0 with `$fatal`).
- Selected fractional depths use integer arithmetic; power-of-two depth makes all four choices integral.

## Verification

The self-checking testbench exercises:

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

Commands:

```bash
make lint
make iverilog
make coverage-report
```

`make coverage-report` runs separate Verilator line and toggle builds. Functional bins are reported by the testbench. Generated coverage files and build products are ignored by Git.

`make iverilog` runs two programs: the main testbench and the flush-resume regression (`tb/tb_flush_hazard.sv`), which fixes a 5 MHz / 50 MHz / 500 MHz clock ratio that makes the flush window large enough for the pre-fix wedge to appear. The regression is Icarus-only; Verilator coverage keeps the main testbench as its single top.

The `FORMAL` assertions are simulation/formal-only. Icarus parses them but does not implement concurrent assertions, so use `iverilog -g2012 -gsupported-assertions -DFORMAL` to syntax-check that variant; Verilator accepts it under `--assert`.

## Synthesis and Timing

- Preserve the two-stage synchronizers and reset synchronizers.
- Apply asynchronous clock-group constraints between `wr_clk`, `rd_clk`, and `cfg_clk`.
- Review `fpga/constraints.sdc`; adapt object paths to the synthesis tool.
- Constrain Gray buses for skew where supported, so source bits cannot arrive more than one fast-clock period apart.
- Confirm dual-port memory inference in synthesis reports.
