#!/usr/bin/env bash
# =============================================================================
# run_sim.sh - Chay mo phong Cadence Xcelium truc tiep tren server EDA
# Usage:
#   ./scripts/run_sim.sh [full|boot|all] [rtl|syn|pnr] [vcd]
# =============================================================================
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_DIR"

TEST="${1:-all}"
MODE="${2:-rtl}"
VCD_OPT="${3:-}"
PDK_DIR="${PDK:-${PDK_ROOT:-$HOME/PDK_GPDK45}}"

mkdir -p work_sim reports/sim

PLUSARGS=""
if [ "$VCD_OPT" = "vcd" ]; then
    PLUSARGS="+DUMP_VCD"
fi

run_one() {
    local tb="$1"
    local log="reports/sim/${tb}_${MODE}.log"
    echo ">>> [XCELIUM] Running $tb (mode=$MODE) ..."

    if [ "$MODE" = "rtl" ]; then
        xrun -64bit -v2001 +access+rwc -incdir rtl \
            -f rtl/filelist_soc.f \
            sim/sram_2k_macro.v \
            "sim/${tb}.v" \
            -top "$tb" \
            -timescale 1ns/1ps \
            $PLUSARGS \
            -xmlibdirname "work_sim/xcelium_${tb}_${MODE}.d" \
            -log "$log"
    elif [ "$MODE" = "syn" ]; then
        # Zero-delay functional post-synthesis GLS (disable specify timing checks without SDF)
        xrun -64bit +access+rwc +define+GATE_SIM \
            -nospecify -notimingchecks \
            "$PDK_DIR/lib/slow_vdd1v0_basiccells.v" \
            sim/sram_2k_macro.v \
            outputs/soc_syn.v \
            "sim/${tb}.v" \
            -top "$tb" \
            -timescale 1ns/1ps \
            $PLUSARGS \
            -xmlibdirname "work_sim/xcelium_${tb}_${MODE}.d" \
            -log "$log"
    elif [ "$MODE" = "pnr" ]; then
        # Default: zero-delay functional post-PnR GLS (-nospecify -notimingchecks avoids false CTS hold 'x').
        # Set GLS_SDF=1 when outputs/soc_top.sdf is present to run SDF back-annotated timing GLS.
        local gls_args=("-nospecify" "-notimingchecks")
        if [ "${GLS_SDF:-0}" = "1" ]; then
            if [ -f "outputs/soc_top.sdf" ]; then
                local sdf_compiled="work_sim/soc_top.sdf.X"
                local sdf_cmd="work_sim/sdf_${tb}.cmd"
                xmsdfc -compile outputs/soc_top.sdf -output "$sdf_compiled"
                cat > "$sdf_cmd" <<EOF
COMPILED_SDF_FILE = "${sdf_compiled}",
SCOPE = ${tb}.u_soc_top,
MTM_CONTROL = "MAXIMUM";
EOF
                gls_args=("-sdf_cmd_file" "$sdf_cmd")
                echo ">>> [XCELIUM] Using compiled SDF back-annotation: $sdf_compiled"
            else
                echo "WARNING: GLS_SDF=1 requested but outputs/soc_top.sdf is missing; falling back to zero-delay GLS (-nospecify -notimingchecks)." >&2
            fi
        fi
        xrun -64bit +access+rwc +define+GATE_SIM \
            "${gls_args[@]}" \
            "$PDK_DIR/lib/slow_vdd1v0_basiccells.v" \
            sim/sram_2k_macro.v \
            outputs/soc_top_final_pr.v \
            "sim/${tb}.v" \
            -top "$tb" \
            -timescale 1ns/1ps \
            $PLUSARGS \
            -xmlibdirname "work_sim/xcelium_${tb}_${MODE}.d" \
            -log "$log"
    else
        echo "Unsupported mode: $MODE (use rtl|syn|pnr)" >&2
        exit 2
    fi

    if grep -q '\[FATAL\]' "$log" || ! grep -q 'PASS' "$log"; then
        echo "[-] Xcelium $tb ($MODE) FAILED! See $log" >&2
        exit 1
    fi
}

case "$TEST" in
    full) run_one tb_soc_full ;;
    boot) run_one tb_soc_bootloader ;;
    all)
        run_one tb_soc_full
        run_one tb_soc_bootloader
        ;;
    *)
        echo "Usage: $0 [full|boot|all] [rtl|syn|pnr] [vcd]" >&2
        exit 2
        ;;
esac

echo "[+] Xcelium simulation(s) complete! Logs in reports/sim/"
