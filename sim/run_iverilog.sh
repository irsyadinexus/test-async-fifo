#!/usr/bin/env bash
# run_iverilog.sh — Simulate async FIFO with Icarus Verilog
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

RTL_DIR="$PROJ_DIR/rtl"
TB_DIR="$PROJ_DIR/tb"
OUT="$SCRIPT_DIR/tb_out.vvp"
OUT2="$SCRIPT_DIR/tb_hazard.vvp"

echo "[INFO] Compiling with Icarus Verilog..."
iverilog -g2012 -o "$OUT" \
  -I "$RTL_DIR" \
  "$RTL_DIR/async_fifo.sv" \
  "$TB_DIR/tb_async_fifo.sv"

echo "[INFO] Running simulation..."
vvp "$OUT"

echo "[INFO] Compiling flush-hazard regression with Icarus Verilog..."
iverilog -g2012 -o "$OUT2" \
  -I "$RTL_DIR" \
  "$RTL_DIR/async_fifo.sv" \
  "$TB_DIR/tb_flush_hazard.sv"

echo "[INFO] Running flush-hazard regression..."
vvp "$OUT2"

echo "[INFO] Done."
