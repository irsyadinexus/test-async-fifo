#!/usr/bin/env bash
# run_iverilog.sh — Simulate async FIFO with Icarus Verilog
#   run_iverilog.sh            functional + flush-hazard + two-FIFO chain
#   run_iverilog.sh two-fifo   two-FIFO chain only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

RTL_DIR="$PROJ_DIR/rtl"
TB_DIR="$PROJ_DIR/tb"
OUT="$SCRIPT_DIR/tb_out.vvp"
OUT2="$SCRIPT_DIR/tb_hazard.vvp"
OUT3="$SCRIPT_DIR/tb_two.vvp"

compile_and_run() { # $1 = label, $2 = vvp output, $3 = testbench file
  echo "[INFO] Compiling $1 with Icarus Verilog..."
  iverilog -g2012 -o "$2" \
    -I "$RTL_DIR" \
    "$RTL_DIR/async_fifo.sv" \
    "$TB_DIR/$3"

  echo "[INFO] Running $1..."
  vvp "$2"
}

case "${1:-all}" in
  all)
    compile_and_run "simulation" "$OUT" tb_async_fifo.sv
    compile_and_run "flush-hazard regression" "$OUT2" tb_flush_hazard.sv
    compile_and_run "two-FIFO chain simulation" "$OUT3" tb_two_fifo.sv
    ;;
  two-fifo)
    compile_and_run "two-FIFO chain simulation" "$OUT3" tb_two_fifo.sv
    ;;
  *)
    echo "usage: $0 [all|two-fifo]" >&2
    exit 2
    ;;
esac

echo "[INFO] Done."