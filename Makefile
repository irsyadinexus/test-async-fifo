.PHONY: sim iverilog lint

sim:
	bash sim/run_verilator.sh

iverilog:
	bash sim/run_iverilog.sh

lint:
	verilator --lint-only -Wall -Wno-fatal -Irtl rtl/async_fifo_pkg.sv rtl/async_fifo.sv
