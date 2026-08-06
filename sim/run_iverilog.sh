#!/usr/bin/env bash
# run_iverilog.sh — Simulate async FIFO with Icarus Verilog
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

RTL_DIR="$PROJ_DIR/rtl"
TB_DIR="$PROJ_DIR/tb"
OUT="$SCRIPT_DIR/tb_out.vvp"

echo "[INFO] Compiling with Icarus Verilog..."
iverilog -g2012 -o "$OUT" \
  -I "$RTL_DIR" \
  "$RTL_DIR/async_fifo_pkg.sv" \
  "$RTL_DIR/async_fifo.sv" \
  "$TB_DIR/tb_async_fifo.sv"

echo "[INFO] Running simulation..."
vvp "$OUT"

echo "[INFO] Done."
