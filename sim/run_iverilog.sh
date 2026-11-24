#!/usr/bin/env bash
# run_iverilog.sh — Simulate async FIFO with Icarus Verilog
#   run_iverilog.sh            functional + flush-hazard + two-FIFO chain
#                              + APB / AHB / AXI-Stream wrapper testbenches
#   run_iverilog.sh two-fifo   two-FIFO chain only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

RTL_DIR="$PROJ_DIR/rtl"
TB_DIR="$PROJ_DIR/tb"
OUT="$SCRIPT_DIR/tb_out.vvp"
OUT2="$SCRIPT_DIR/tb_hazard.vvp"
OUT3="$SCRIPT_DIR/tb_two.vvp"
OUT4="$SCRIPT_DIR/tb_apb_wrapper.vvp"
OUT5="$SCRIPT_DIR/tb_ahb_wrapper.vvp"
OUT6="$SCRIPT_DIR/tb_axis_wrapper.vvp"

compile_and_run() { # $1 = label, $2 = vvp output, $3 = testbench, rest = extra RTL
  local label="$1" out="$2" tb="$3"
  shift 3
  echo "[INFO] Compiling $label with Icarus Verilog..."
  iverilog -g2012 -o "$out" \
    -I "$RTL_DIR" \
    "$RTL_DIR/async_fifo.sv" \
    "$@" \
    "$TB_DIR/$tb"

  echo "[INFO] Running $label..."
  vvp "$out"
}

case "${1:-all}" in
  all)
    compile_and_run "simulation" "$OUT" tb_async_fifo.sv
    compile_and_run "flush-hazard regression" "$OUT2" tb_flush_hazard.sv
    compile_and_run "two-FIFO chain simulation" "$OUT3" tb_two_fifo.sv
    compile_and_run "APB wrapper simulation" "$OUT4" tb_apb_wrapper.sv \
      "$RTL_DIR/fifo_apb_cfg.sv" "$RTL_DIR/fifo_apb_wrapper.sv"
    compile_and_run "AHB wrapper simulation" "$OUT5" tb_ahb_wrapper.sv \
      "$RTL_DIR/fifo_apb_cfg.sv" "$RTL_DIR/fifo_ahb_wrapper.sv"
    compile_and_run "AXI-Stream wrapper simulation" "$OUT6" tb_axis_wrapper.sv \
      "$RTL_DIR/fifo_axis_wrapper.sv"
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