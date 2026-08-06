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

`wr_rst_n` and `rd_rst_n` assert state reset asynchronously. Internal two-stage reset synchronizers release reset on the respective clock. Requests remain blocked until release completes.

`cfg_rst_n` resets configuration registers to:

- almost-empty: `ceil(DEPTH / 5)`
- almost-full: `ceil(4 × DEPTH / 5)`
- active depth: `DEPTH`

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

A write occurs on `cfg_clk` when `cfg_we` is high.

| Address | Function | Data |
|---:|---|---|
| 0 | Almost-empty threshold | Unsigned entry count |
| 1 | Almost-full threshold | Unsigned entry count |
| 2 | Active-depth selector | Low two bits: full, 75%, 50%, 25% |
| 3 | Reserved | Ignored |

Thresholds saturate at physical `DEPTH`. Active depth should only change while `empty` is asserted and no read/write request is active. There is no hardware handshake or rejection for an unsafe depth change.

Configuration registers are binary at the external interface, encoded to Gray internally, synchronized into their consuming domains, then decoded. Hold each configuration value stable until the next write. Avoid back-to-back changes faster than both destination domains can observe; Gray encoding guarantees a single-bit transition only between adjacent numeric values, while arbitrary software writes can change multiple Gray bits. For strict atomic arbitrary-value CDC, add a request/acknowledge handshake.

## Parameter Constraints

- `DEPTH` must be a power of two.
- `DEPTH` should be at least 4 for all depth modes to remain meaningful.
- `ADDR_W` should remain `$clog2(DEPTH)`.
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

Commands:

```bash
make lint
make iverilog
make coverage-report
```

`make coverage-report` runs separate Verilator line and toggle builds. Functional bins are reported by the testbench. Generated coverage files and build products are ignored by Git.

## Synthesis and Timing

- Preserve the two-stage synchronizers and reset synchronizers.
- Apply asynchronous clock-group constraints between `wr_clk`, `rd_clk`, and unrelated `cfg_clk`.
- Review `fpga/constraints.sdc`; adapt object paths to the synthesis tool.
- Constrain Gray buses for skew where supported, so source bits cannot arrive more than one fast-clock period apart.
- Confirm dual-port memory inference in synthesis reports.
