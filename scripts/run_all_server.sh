#!/usr/bin/env bash
# ==============================================================================
# run_all_server.sh - Run ASIC RTL-to-GDSII Flow directly on EDA Linux Server
# Compatible with MobaXterm / standard SSH terminal (pure bash, no client tools)
#
# Usage (from project root on server):
#   export PDK=$HOME/PDK_GPDK45
#   ./scripts/run_all_server.sh sim        # 1. Xcelium RTL simulation
#   ./scripts/run_all_server.sh syn_icg    # 2A. Genus 100 MHz + ICG Clock Gating
#   ./scripts/run_all_server.sh syn        # 2B. Genus 100 MHz Baseline
#   ./scripts/run_all_server.sh sweep      # 2C. Genus 250/200/150/100 MHz sweep
#   ./scripts/run_all_server.sh lec        # 3. Conformal LEC (RTL vs Netlist)
#   ./scripts/run_all_server.sh pnr        # 4. Innovus 2-Corner PnR -> GDSII
#   ./scripts/run_all_server.sh tempus     # 5. Tempus 2-Corner STA Sign-off
#   ./scripts/run_all_server.sh gls        # 6. Xcelium Post-PnR GLS
#   ./scripts/run_all_server.sh area_ppa   # 7. 6-point Area-vs-Power @ 100 MHz
#   ./scripts/run_all_server.sh all        # Run sim -> syn_icg -> sweep -> lec -> pnr -> tempus -> gls
#   ./scripts/run_all_server.sh status     # Print quick summary of logs/reports
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

export PDK="${PDK:-${PDK_ROOT:-$HOME/PDK_GPDK45}}"
export PDK_ROOT="$PDK"

STAGE="${1:-help}"

check_pdk() {
    if [ ! -d "$PDK/lib" ]; then
        echo "[ERROR] Cannot find PDK library directory: $PDK/lib" >&2
        echo "        Please run: export PDK=/path/to/PDK_GPDK45" >&2
        exit 1
    fi
}

case "$STAGE" in
    sim)
        ./scripts/run_sim.sh all rtl
        ;;
    syn)
        check_pdk
        mkdir -p work_syn reports/syn outputs
        genus -no_gui -files scripts/run_genus_soc.tcl -log work_syn/genus.log < /dev/null
        ;;
    syn_icg)
        check_pdk
        mkdir -p work_syn reports/syn/run_100.0MHz_icg outputs
        SOC_ENABLE_ICG=1 genus -no_gui -files scripts/run_genus_soc.tcl -log work_syn/genus_icg.log < /dev/null
        cp -f reports/syn/*.rpt reports/syn/run_100.0MHz_icg/ 2>/dev/null || true
        ;;
    sweep)
        check_pdk
        ./scripts/sweep_frequencies.sh
        ;;
    lec)
        check_pdk
        mkdir -p reports/lec
        lec -xl -nogui -dofile scripts/run_lec.do < /dev/null
        ;;
    pnr)
        check_pdk
        mkdir -p work_pnr reports/pnr outputs
        innovus -no_gui -files scripts/run_innovus_soc.tcl -log work_pnr/innovus.log < /dev/null
        ;;
    tempus)
        check_pdk
        mkdir -p reports/pnr/tempus
        tempus -no_gui -files scripts/run_tempus_soc.tcl -log reports/pnr/tempus.log < /dev/null
        ;;
    gls)
        check_pdk
        ./scripts/run_sim.sh all pnr
        ;;
    area_ppa)
        check_pdk
        ./scripts/sweep_area_ppa_100mhz.sh
        ;;
    all)
        "$0" sim
        "$0" syn_icg
        "$0" sweep
        "$0" lec || true
        "$0" pnr
        "$0" tempus
        "$0" gls
        ;;
    status)
        echo "=== PDK: $PDK ==="
        echo "--- Simulation Logs ---"
        grep -hE 'PASS|FAIL|FATAL|MCYCLE' reports/sim/*.log 2>/dev/null || echo "(none)"
        echo "--- Frequency Sweep ---"
        cat reports/syn/frequency_sweep_summary.md 2>/dev/null || echo "(not run yet)"
        echo "--- Area-vs-Power 100 MHz Table ---"
        cat reports/pnr/area_ppa_tradeoff_100mhz.md 2>/dev/null || echo "(not run yet)"
        echo "--- Outputs ---"
        ls -lh outputs/ 2>/dev/null || echo "(none)"
        ;;
    *)
        echo "Usage: $0 {sim|syn|syn_icg|sweep|lec|pnr|tempus|gls|area_ppa|all|status}"
        exit 1
        ;;
esac
