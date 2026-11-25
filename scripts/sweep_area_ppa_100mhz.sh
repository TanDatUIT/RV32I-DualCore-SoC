#!/usr/bin/env bash
# ==============================================================================
# sweep_area_ppa_100mhz.sh - Faraday-style Area-vs-Power PPA Trade-off Sweep
# Project : SoC Physical Design Final Project (Cadence GPDK 45nm)
# Goal    : Fix clock = 100 MHz (10.0 ns), sweep Target Utilization from 50%
#           up to 85% (shrinking Die/Core Area step-by-step) + ICG @ 65%,
#           measuring Die/Core Area, Actual Density, StdCell Count, Wirelength,
#           Congestion, Setup/Hold WNS/TNS, Clock Skew, Power Breakdown, DRC.
# NOTE    : Uses pure bash/awk/sed (no python3, safe under Cadence env on EDA server).
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

export PDK="${PDK:-$HOME/PDK_GPDK45}"
export PDK_ROOT="$PDK"

BASE_V="$PROJECT_ROOT/outputs/soc_syn_100.0MHz.v"
BASE_SDC="$PROJECT_ROOT/outputs/soc_syn_100.0MHz.sdc"
[ -f "$BASE_V" ]   || BASE_V="$PROJECT_ROOT/outputs/soc_syn.v"
[ -f "$BASE_SDC" ] || BASE_SDC="$PROJECT_ROOT/outputs/soc_syn.sdc"

ICG_V="$PROJECT_ROOT/outputs/soc_syn_icg.v"
ICG_SDC="$PROJECT_ROOT/outputs/soc_syn_icg.sdc"

SWEEP_RPT_ROOT="$PROJECT_ROOT/reports/pnr/area_sweep"
SWEEP_WORK_ROOT="$PROJECT_ROOT/work_pnr/area_sweep"
TABLE_FILE="$PROJECT_ROOT/reports/pnr/area_ppa_tradeoff_100mhz.md"
STATUS_FILE="$SWEEP_WORK_ROOT/sweep_status.txt"

mkdir -p "$SWEEP_RPT_ROOT" "$SWEEP_WORK_ROOT"
: > "$STATUS_FILE"

log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$STATUS_FILE"
}

if [ ! -f "$BASE_V" ]; then
    log_msg "ERROR: Missing Baseline 100 MHz netlist ($BASE_V). Run Genus synthesis first."
    exit 1
fi

# Format: TAG:LABEL:UTIL:NETLIST:SDC
SCENARIOS=(
    "FP1_u50:FP1 (Base 50%):0.50:$BASE_V:$BASE_SDC"
    "FP2_u60:FP2 (Base 60%):0.60:$BASE_V:$BASE_SDC"
    "FP3_u70:FP3 (Base 70%):0.70:$BASE_V:$BASE_SDC"
    "FP4_u78:FP4 (Base 78%):0.78:$BASE_V:$BASE_SDC"
    "FP5_u85:FP5 (Base 85%):0.85:$BASE_V:$BASE_SDC"
)

if [ -f "$ICG_V" ] && [ -f "$ICG_SDC" ]; then
    SCENARIOS+=("FP6_icg_u65:FP6 (ICG 65%):0.65:$ICG_V:$ICG_SDC")
else
    log_msg "WARN: $ICG_V not found; skipping FP6_icg_u65."
fi

cat > "$TABLE_FILE" <<'EOF'
# Bảng Đánh Đổi PPA Chuẩn Faraday — Giảm Dần Area @ Cố Định 100 MHz (GPDK 45nm, Post-Route 2-Corner OCV+CPPR)

> So sánh các mức **Target Utilization** từ `50%` đến `85%` (thu nhỏ Die Area dần ở cùng tần số `100 MHz / 10.0 ns`) kèm cấu hình **ICG Clock Gating (`65%`)**.

| Kịch bản | Target Util | Die Area (µm²) | Core Area (µm²) | Density (%) | StdCells | Wirelength (µm) | Cong. H/V (%) | Setup WNS / TNS (ns) | Hold WNS / THS (ns) | Skew (ns) | Internal (mW) | Switching (mW) | Leakage (mW) | Total Power (mW) | DRC / Ant / Conn | Trạng thái |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
EOF

extract_summary_metric() {
    local rpt="$1"
    local pattern="$2"
    if [ ! -f "$rpt" ]; then echo "N/A"; return; fi
    awk -v pat="$pattern" '$0 ~ pat {for (i=NF; i>=1; i--) if ($i ~ /^-?[0-9]+(\.[0-9]+)?%?$/ || $i ~ /^-?[0-9]+\.[0-9]+e[+-]?[0-9]+$/) {print $i; exit}}' "$rpt" | sed 's/%$//'
}

parse_timing_pair() {
    local dir="$1"
    local prefix="$2"
    local f=""
    for cand in \
        "$dir/${prefix}.summary" \
        "$dir/${prefix}.summary.gz" \
        "$dir/${prefix}_all.summary" \
        "$dir/${prefix}_all.summary.gz"; do
        if [ -f "$cand" ]; then f="$cand"; break; fi
    done
    if [ -z "$f" ]; then echo "N/A / N/A"; return; fi
    local content=""
    case "$f" in
        *.gz) content="$(gzip -dc "$f" 2>/dev/null || true)" ;;
        *)    content="$(cat "$f" 2>/dev/null || true)" ;;
    esac
    local wns tns
    wns="$(printf '%s\n' "$content" | awk '/WNS \(ns\):/ {print $4; exit}')"
    tns="$(printf '%s\n' "$content" | awk '/TNS \(ns\):/ {print $4; exit}')"
    [ -z "$wns" ] && wns="N/A"
    [ -z "$tns" ] && tns="N/A"
    echo "${wns} / ${tns}"
}

for sc in "${SCENARIOS[@]}"; do
    IFS=':' read -r TAG LABEL UTIL NET_PATH SDC_PATH <<< "$sc"
    RUN_WORK="$SWEEP_WORK_ROOT/$TAG"
    RUN_RPT="$SWEEP_RPT_ROOT/$TAG"
    mkdir -p "$RUN_WORK" "$RUN_RPT"

    log_msg "START $TAG ($LABEL | Util=$UTIL | Netlist=$(basename "$NET_PATH"))"

    SOC_RUN_TAG="$TAG" \
    SOC_UTIL="$UTIL" \
    SOC_NETLIST="$NET_PATH" \
    SOC_SDC="$SDC_PATH" \
    innovus -no_gui -files "$PROJECT_ROOT/scripts/run_innovus_soc.tcl" \
        -log "$RUN_WORK/innovus_${TAG}.log" < /dev/null \
        > "$RUN_WORK/stdout_${TAG}.log" 2>&1
    RC=$?

    SUM_RPT="$RUN_RPT/signoff/design_summary.rpt"
    PWR_RPT="$RUN_RPT/signoff/power.rpt"
    CONG_RPT="$RUN_RPT/placement/congestion.rpt"
    SKEW_RPT="$RUN_RPT/cts/skew_groups.rpt"
    DRC_RPT="$RUN_RPT/route/drc_fixed.rpt"
    ANT_RPT="$RUN_RPT/route/antenna.rpt"
    CONN_RPT="$RUN_RPT/route/connectivity.rpt"

    DIE_AREA="$(extract_summary_metric "$SUM_RPT" 'Total area of Chip:')"
    CORE_AREA="$(extract_summary_metric "$SUM_RPT" 'Total area of Core:')"
    DENSITY="$(extract_summary_metric "$SUM_RPT" 'Total area of Standard cells / Core area|Effective density|Density\(with all' )"
    [ -z "$DENSITY" ] && DENSITY="$(awk '/Density|Utilization/ && $0 ~ /[0-9]+\.[0-9]+%/ {match($0, /[0-9]+\.[0-9]+%/); print substr($0, RSTART, RLENGTH-1); exit}' "$RUN_RPT/signoff/density.rpt" 2>/dev/null || true)"
    STDCELLS="$(extract_summary_metric "$SUM_RPT" 'Total number of Standard Cells:')"
    WIRELEN="$(extract_summary_metric "$SUM_RPT" 'Total length of regular wires|Total wire length:')"

    CONG_HV="N/A"
    if [ -f "$CONG_RPT" ]; then
        CONG_H="$(awk '/Overflow:/ && /H/ {for(i=1;i<=NF;i++) if($i ~ /%$/) {print $i; exit}}' "$CONG_RPT" 2>/dev/null || true)"
        CONG_V="$(awk '/Overflow:/ && /V/ {for(i=1;i<=NF;i++) if($i ~ /%$/) {print $i; exit}}' "$CONG_RPT" 2>/dev/null || true)"
        if [ -n "$CONG_H" ] || [ -n "$CONG_V" ]; then
            CONG_HV="${CONG_H:-0%} / ${CONG_V:-0%}"
        fi
    fi

    SETUP_WT="$(parse_timing_pair "$RUN_RPT/signoff" "signoff_setup")"
    HOLD_WT="$(parse_timing_pair "$RUN_RPT/signoff" "signoff_hold")"

    SKEW="N/A"
    if [ -f "$SKEW_RPT" ]; then
        SKEW="$(awk '/Max Skew|Skew:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}' "$SKEW_RPT" 2>/dev/null || true)"
        [ -z "$SKEW" ] && SKEW="N/A"
    fi

    P_INT="N/A"; P_SW="N/A"; P_LKG="N/A"; P_TOT="N/A"
    if [ -f "$PWR_RPT" ]; then
        P_INT="$(awk '/^Total Internal Power:/ {printf "%.4f", $4; exit}' "$PWR_RPT" 2>/dev/null || true)"
        P_SW="$(awk '/^Total Switching Power:/ {printf "%.4f", $4; exit}' "$PWR_RPT" 2>/dev/null || true)"
        P_LKG="$(awk '/^Total Leakage Power:/ {printf "%.4f", $4; exit}' "$PWR_RPT" 2>/dev/null || true)"
        P_TOT="$(awk '/^Total Power:/ {printf "%.4f", $3; exit}' "$PWR_RPT" 2>/dev/null || true)"
        [ -z "$P_INT" ] && P_INT="N/A"
        [ -z "$P_SW" ]  && P_SW="N/A"
        [ -z "$P_LKG" ] && P_LKG="N/A"
        [ -z "$P_TOT" ] && P_TOT="N/A"
    fi

    DRC_CNT="N/A"
    if [ -f "$DRC_RPT" ]; then
        if grep -q "No DRC violations were found" "$DRC_RPT"; then
            DRC_CNT="0"
        else
            DRC_CNT="$(awk '/Verification Complete :|Total Violations/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; exit}}' "$DRC_RPT" 2>/dev/null || echo "?")"
        fi
    fi
    ANT_CNT="N/A"
    if [ -f "$ANT_RPT" ]; then
        if grep -q "No Violations Found" "$ANT_RPT"; then
            ANT_CNT="0"
        else
            ANT_CNT="$(awk '/Total number of process antenna violations/ {print $NF; exit}' "$ANT_RPT" 2>/dev/null || echo "?")"
        fi
    fi
    CONN_CNT="N/A"
    if [ -f "$CONN_RPT" ]; then
        if grep -q "Found no problems or warnings" "$CONN_RPT"; then
            CONN_CNT="0"
        else
            CONN_CNT="$(awk '/Problem|Warning/ {c++} END {print c+0}' "$CONN_RPT" 2>/dev/null || echo "?")"
        fi
    fi

    [ -z "$DIE_AREA" ]  && DIE_AREA="N/A"
    [ -z "$CORE_AREA" ] && CORE_AREA="N/A"
    [ -z "$DENSITY" ]   && DENSITY="N/A"
    [ -z "$STDCELLS" ]  && STDCELLS="N/A"
    [ -z "$WIRELEN" ]   && WIRELEN="N/A"

    STATE="PASS"
    [ $RC -ne 0 ] && STATE="FAIL(rc=$RC)"

    echo "| $LABEL | ${UTIL} | $DIE_AREA | $CORE_AREA | $DENSITY | $STDCELLS | $WIRELEN | $CONG_HV | $SETUP_WT | $HOLD_WT | $SKEW | $P_INT | $P_SW | $P_LKG | **$P_TOT** | ${DRC_CNT} / ${ANT_CNT} / ${CONN_CNT} | $STATE |" >> "$TABLE_FILE"
    log_msg "DONE $TAG ($STATE) -> Die=$DIE_AREA, Power=${P_TOT}mW, Setup=$SETUP_WT, Hold=$HOLD_WT, DRC=$DRC_CNT"
done

log_msg "AREA_SWEEP_ALL_FINISHED -> $TABLE_FILE"
cat "$TABLE_FILE"
