.PHONY: sim coverage coverage-line coverage-toggle coverage-report iverilog lint

sim:
	bash sim/run_verilator.sh

coverage: sim
	verilator_coverage --annotate coverage-annotated coverage.dat

coverage-line:
	rm -rf obj_dir coverage.dat
	COVERAGE_KIND=line bash sim/run_verilator.sh

coverage-toggle:
	rm -rf obj_dir coverage.dat
	COVERAGE_KIND=toggle bash sim/run_verilator.sh

coverage-report: coverage-line coverage-toggle
	python3 sim/coverage_report.py coverage-line.info coverage-toggle.info

iverilog:
	bash sim/run_iverilog.sh

lint:
	verilator --lint-only -Wall -Wno-fatal -Irtl rtl/async_fifo_pkg.sv rtl/async_fifo.sv
