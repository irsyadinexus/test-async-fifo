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
