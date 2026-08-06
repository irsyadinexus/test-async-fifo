#!/usr/bin/env bash
# run_verilator.sh — Simulate async FIFO with Verilator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

RTL_DIR="$PROJ_DIR/rtl"
TB_DIR="$PROJ_DIR/tb"

echo "[INFO] Compiling with Verilator..."
verilator --binary --timing \
  -Wno-fatal \
  -I"$RTL_DIR" \
  "$RTL_DIR/async_fifo_pkg.sv" \
  "$RTL_DIR/async_fifo.sv" \
  "$TB_DIR/tb_async_fifo.sv" \
  --top tb_async_fifo \
  -o tb_async_fifo_bin

echo "[INFO] Running simulation..."
"$PROJ_DIR/obj_dir/tb_async_fifo_bin"

echo "[INFO] Done."
