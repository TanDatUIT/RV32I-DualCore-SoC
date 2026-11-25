#!/usr/bin/env bash
# ==============================================================================
# sweep_frequencies.sh - Multi-Frequency Synthesis Sweep Loop on EDA server
# Project : SoC Physical Design Final Project (Cadence GPDK 45nm)
# Usage   : ./scripts/sweep_frequencies.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Run 100.0 MHz last so outputs/soc_syn.{v,sdc} remain at 100 MHz for PnR
FREQS=("250.0:4.0" "200.0:5.0" "150.0:6.667" "100.0:10.0")
TABLE_FILE="reports/syn/frequency_sweep_summary.md"
mkdir -p work_syn outputs reports/syn

echo "================================================================================"
echo " MULTI-FREQUENCY ASIC SYNTHESIS SWEEP LOOP (Cadence Genus GPDK 45nm)"
echo "================================================================================"

cat > "$TABLE_FILE" <<'EOF'
# Bảng Khảo Sát Tần Số Đa Kịch Bản (Cadence Genus GPDK45)

| Kịch bản | Tần số (MHz) | Chu kỳ (ns) | Trạng thái Genus | WNS (ns) | TNS (ns) | Diện tích Cell (µm²) | Công suất (mW) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
EOF

for item in "${FREQS[@]}"; do
    FREQ="${item%%:*}"
    PERIOD="${item##*:}"
    echo ""
    echo ">>> [LOOP] Running Synthesis for Clock Target: $FREQ MHz (Period: $PERIOD ns) ..."

    export SOC_CLK_PERIOD="$PERIOD"
    genus -no_gui -files scripts/run_genus_soc.tcl -log "work_syn/genus_${FREQ}MHz.log" < /dev/null

    FREQ_RPT_DIR="reports/syn/run_${FREQ}MHz"
    mkdir -p "$FREQ_RPT_DIR"
    cp -f reports/syn/*.rpt "$FREQ_RPT_DIR/" 2>/dev/null || true
    cp -f outputs/soc_syn.v   "outputs/soc_syn_${FREQ}MHz.v"   2>/dev/null || true
    cp -f outputs/soc_syn.sdc "outputs/soc_syn_${FREQ}MHz.sdc" 2>/dev/null || true

    QOR_FILE="reports/syn/qor.rpt"
    PWR_FILE="reports/syn/power.rpt"

    WNS="N/A"
    TNS="N/A"
    AREA="N/A"
    POWER="N/A"

    # Genus 21.10 reports timing in ps and total power in W.
    # Match Cost Group row (NF>=4: "clk <slack_ps> <tns_ps> <viol>") rather than Clock Period row (NF==2).
    if [ -f "$QOR_FILE" ]; then
        WNS=$(awk '/^[[:space:]]*clk[[:space:]]+/ && NF>=4 && $2 ~ /^-?[0-9]/ {printf "%.3f", $2/1000.0; exit}' "$QOR_FILE" || true)
        TNS=$(awk '/^[[:space:]]*clk[[:space:]]+/ && NF>=4 && $3 ~ /^-?[0-9]/ {printf "%.3f", $3/1000.0; exit}' "$QOR_FILE" || true)
        AREA=$(awk '/^Total Area/ {print $NF; exit}' "$QOR_FILE" || true)
        [ -z "$WNS" ] && WNS="N/A"
        [ -z "$TNS" ] && TNS="N/A"
        [ -z "$AREA" ] && AREA="N/A"
    fi
    if [ -f "$PWR_FILE" ]; then
        POWER=$(awk '/^[[:space:]]*Subtotal/ {printf "%.4f", $5*1000.0; exit}' "$PWR_FILE" || true)
        [ -z "$POWER" ] && POWER="N/A"
    fi

    echo "| $FREQ MHz | $FREQ | $PERIOD | Xong | $WNS | $TNS | $AREA | $POWER |" >> "$TABLE_FILE"
    echo ">>> [RESULT] $FREQ MHz -> WNS: $WNS ns, TNS: $TNS ns, Area: $AREA um2, Power: $POWER mW"
done

echo ""
echo "================================================================================"
echo "[+] Frequency sweep loop completed! Summary written to: $TABLE_FILE"
echo "================================================================================"
cat "$TABLE_FILE"
