#!/usr/bin/env bash
# run_verilator.sh — Simulate async FIFO with Verilator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

RTL_DIR="$PROJ_DIR/rtl"
TB_DIR="$PROJ_DIR/tb"

echo "[INFO] Compiling with Verilator..."
COVERAGE_KIND="${COVERAGE_KIND:-all}"
case "$COVERAGE_KIND" in
  line)   COVERAGE_FLAG=--coverage-line ;;
  toggle) COVERAGE_FLAG=--coverage-toggle ;;
  all)    COVERAGE_FLAG=--coverage ;;
  *) echo "Unknown COVERAGE_KIND: $COVERAGE_KIND" >&2; exit 2 ;;
esac

verilator --cc --exe --build --timing "$COVERAGE_FLAG" \
  -Wno-fatal \
  -I"$RTL_DIR" \
  "$RTL_DIR/async_fifo_pkg.sv" \
  "$RTL_DIR/async_fifo.sv" \
  "$TB_DIR/tb_async_fifo.sv" \
  "$SCRIPT_DIR/sim_main.cpp" \
  --top tb_async_fifo \
  -o tb_async_fifo_bin

echo "[INFO] Running simulation..."
(cd "$PROJ_DIR" && "$PROJ_DIR/obj_dir/tb_async_fifo_bin")

echo "[INFO] Writing coverage report..."
verilator_coverage --write-info "$PROJ_DIR/coverage-${COVERAGE_KIND}.info" "$PROJ_DIR/coverage.dat"

echo "[INFO] Done."
