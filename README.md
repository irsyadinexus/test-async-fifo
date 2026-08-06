# Async Dual-Clock FIFO — RTL Project

Fully synthesizable asynchronous (dual-clock) FIFO written in SystemVerilog.

## Architecture

```
        ┌─────────────────────────────────────────────┐
        │              async_fifo                     │
        │                                             │
  wr_clk ──►  ┌──────────┐    ┌────────────┐          │
  wr_en  ──►  │ Write    │    │ Dual-Port  │          │
  wr_data──►  │ Pointer  │──►│ RAM        │          │
              │ (Gray)   │    │            │          │
              └────┬─────┘    └──────┬─────┘          │
        │        │                 │                │
        │   ┌─────▼──────┐   ┌──────▼─────┐          │
        │   │ 2-Flop Sync │   │ 2-Flop Sync│          │
        │   │ (rd→wr)     │   │ (wr→rd)    │          │
        │   └────────────┘   └────────────┘          │
        │        │                 │                │
        │  full◄──┘    ┌──────────┘──►empty         │
        │                                             │
  rd_clk ──►  ┌──────────┐                            │
  rd_en  ──►  │ Read     │◄── rd_data               │
              │ Pointer  │                            │
              │ (Gray)   │                            │
              └──────────┘                            │
        └─────────────────────────────────────────────┘
```

### Key Design Points

| Feature              | Implementation                              |
|----------------------|---------------------------------------------|
| CDC safety           | 2-flop synchronizers + Gray-code pointers  |
| Full detection       | Write domain, compares synced read ptr    |
| Empty detection      | Read domain, compares synced write ptr     |
| Almost flags         | Programmable occupancy thresholds          |
| RAM style            | Simple dual-port, 1 rw port each side     |
| Reset                | Asynchronous assert, synchronous deassert  |
| Parameterizable      | Data width (DW), depth (DEPTH, pow2)       |

## File Structure

```
async-fifo/
├── rtl/
│   ├── async_fifo.sv          # Top-level FIFO module
│   ├── async_fifo_if.sv       # Interface (optional, for TB/UVM)
│   └── async_fifo_pkg.sv     # Shared package (types, helpers)
├── tb/
│   └── tb_async_fifo.sv      # Comprehensive testbench
├── sim/
│   ├── run_iverilog.sh        # Icarus Verilog simulation script
│   └── run_verilator.sh       # Verilator simulation script
├── fpga/
│   └── constraints.sdc       # Example SDC constraints
└── README.md
```

## Parameters

| Parameter | Default | Description                           |
|-----------|---------|---------------------------------------|
| `DW`      | 8       | Data bus width in bits               |
| `DEPTH`   | 16      | FIFO depth (must be power of two)    |
| `ADDR_W`  | clog2   | Address width (auto from DEPTH)      |

## Interface

### Write Port
| Signal      | Dir | Description                        |
|-------------|-----|------------------------------------|
| `wr_clk`    | I   | Write clock                        |
| `wr_rst_n`  | I   | Active-low reset (sync to wr_clk)  |
| `wr_en`     | I   | Write enable                       |
| `wr_data`   | I   | Write data [DW-1:0]                |
| `full`      | O   | FIFO full flag                     |

### Read Port
| Signal      | Dir | Description                        |
|-------------|-----|------------------------------------|
| `rd_clk`    | I   | Read clock                         |
| `rd_rst_n`  | I   | Active-low reset (sync to rd_clk)  |
| `rd_en`     | I   | Read enable                        |
| `rd_data`   | O   | Read data [DW-1:0]                 |
| `empty`     | O   | FIFO empty flag                    |

### Configuration Port

Write `cfg_wdata` using `cfg_clk`, `cfg_rst_n`, and `cfg_we`. `cfg_addr=0`
sets almost-empty; `cfg_addr=1` sets almost-full. Values saturate at `DEPTH`.
`cfg_addr=2` selects active FIFO depth using `cfg_wdata[1:0]`: `0` = 100%,
`1` = 75%, `2` = 50%, `3` = 25%. Change depth only while FIFO is empty.
Defaults: `ceil(20% * DEPTH)` and `ceil(80% * DEPTH)`. Configuration values
are Gray-encoded before crossing clock domains, then decoded locally.
`almost_empty` is in the `rd_clk` domain; `almost_full` is in the `wr_clk` domain.

## Simulation

### Icarus Verilog
```bash
cd async-fifo
bash sim/run_iverilog.sh
```

### Verilator
```bash
cd async-fifo
bash sim/run_verilator.sh
```

### Coverage

```bash
make coverage
make coverage-report
```

The testbench covers all four active-depth modes, assertion and clearing of
both programmable almost flags, full/empty boundaries, concurrent traffic,
and randomized traffic. Verilator writes `coverage.info` and annotated source
under `coverage-annotated/`.
`make coverage-report` runs and reports line and toggle coverage separately;
functional bins are printed directly by the testbench.

### Make targets
```bash
cd async-fifo
make sim
make iverilog
make lint
```

## Synthesis Notes

- All logic is synthesizable (no `initial` in RTL, no delays)
- Dual-port RAM infers as block RAM on FPGA (or distributed RAM)
- 2-flop synchronizers should be placed in IO/floorplan regions with
  tight clock skew constraints
- SDC: use `set_clock_groups -asynchronous` for wr_clk / rd_clk
- Reset: both resets can share a common source; each must be
  synchronized to its own clock domain

## References

- Cummings, C. E., "Synthesis and Scripting Techniques for Designing
  Multi-Asynchronous Clock Designs," SNUG 2002.
- Cummings, C. E. & Alfke, P., "Simulation and Synthesis Techniques
  for Asynchronous FIFO Design," SNUG 2002.

## License

MIT — see top of source files.
