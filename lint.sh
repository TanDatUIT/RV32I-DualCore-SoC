#!/usr/bin/env bash
# =============================================================================
# lint.sh - Verilator lint check for RV32I SoC
# Project : SoC Physical Design Final Project (Dual-Core RV32I SoC)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[lint] Running Verilator lint on SoC top..."

env -u VERILATOR_ROOT verilator --lint-only -Wall --sv --no-timing \
    -Wno-TIMESCALEMOD -Wno-ASSIGNDLY -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Irtl -f rtl/filelist_soc.f sim/sram_2k_macro.v --top-module soc_top

echo "[lint] SUCCESS: All modules passed lint check with 0 errors and 0 warnings!"
