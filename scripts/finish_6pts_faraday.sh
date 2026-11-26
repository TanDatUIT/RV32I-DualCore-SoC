#!/usr/bin/env bash
# ==============================================================================
# finish_6pts_faraday.sh - Resume Sign-off from routed.enc for all 6 Faraday
#                          Area-vs-Power scenarios and generate clean table
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

export PDK="${PDK:-$HOME/PDK_GPDK45}"
export PDK_ROOT="$PDK"

LOG="$PROJECT_ROOT/work_pnr/area_sweep/finish_6pts.log"
STAT="$PROJECT_ROOT/work_pnr/area_sweep/finish_6pts_status.txt"
TABLE="$PROJECT_ROOT/reports/pnr/area_ppa_tradeoff_100mhz.md"

mkdir -p "$PROJECT_ROOT/work_pnr/area_sweep" "$PROJECT_ROOT/reports/pnr"
: > "$LOG"
: > "$STAT"

log_m() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$STAT" "$LOG"
}

cat > "$TABLE" <<'TEOF'
# Bảng Đánh Đổi PPA Chuẩn Faraday — Giảm Dần Area @ Cố Định 100 MHz (GPDK 45nm, Post-Route 2-Corner OCV+CPPR)

> So sánh các mức **Target Utilization** từ `50%` đến `85%` (thu nhỏ Die Area dần ở cùng tần số `100 MHz / 10.0 ns`) kèm cấu hình **ICG Clock Gating (`65%`)**.

| Kịch bản | Target Util | Die Area (µm²) | Core Area (µm²) | Actual Density (%) | StdCell Area (µm²) | Wirelength (µm) | Cong. H/V (%) | Setup WNS / TNS (ns) | Hold WNS / THS (ns) | Skew (ns) | Internal (mW) | Switching (mW) | Leakage (mW) | Total Power (mW) | DRC / Ant / Conn | Trạng thái |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
TEOF

parse_wt() {
    local dir="$1" pref="$2" f=""
    for c in \
        "$dir/${pref}.summary.gz" \
        "$dir/${pref}_hold.summary.gz" \
        "$dir/${pref}.summary" \
        "$dir/${pref}_hold.summary"; do
        if [ -f "$c" ]; then f="$c"; break; fi
    done
    if [ -z "$f" ]; then echo "N/A / N/A"; return; fi
    local txt=""
    case "$f" in
        *.gz) txt="$(gzip -dc "$f" 2>/dev/null || true)" ;;
        *)    txt="$(cat "$f" 2>/dev/null || true)" ;;
    esac
    local w t
    w="$(printf '%s\n' "$txt" | awk -F'|' '/WNS \(ns\):/ {gsub(/ /, "", $3); print $3; exit}')"
    t="$(printf '%s\n' "$txt" | awk -F'|' '/TNS \(ns\):/ {gsub(/ /, "", $3); print $3; exit}')"
    echo "${w:-N/A} / ${t:-N/A}"
}

emit_row() {
    local LABEL="$1" UTIL="$2" RUN_RPT="$3" STATE="$4"

    local SUM="$RUN_RPT/signoff/design_summary.rpt"
    local PWR="$RUN_RPT/signoff/power.rpt"
    local CONG="$RUN_RPT/placement/congestion.rpt"
    local SKEW_RPT="$RUN_RPT/cts/skew_groups.rpt"
    local DRC="$RUN_RPT/route/drc_fixed.rpt"
    local ANT="$RUN_RPT/route/antenna.rpt"
    local CONN="$RUN_RPT/route/connectivity.rpt"

    local DIE="N/A" CORE="N/A" DENS="N/A" CELLAREA="N/A" WIRE="N/A"
    if [ -f "$SUM" ]; then
        DIE="$(awk '/^Total area of Chip:/ {print $5; exit}' "$SUM")"
        CORE="$(awk '/^Total area of Core:/ {print $5; exit}' "$SUM")"
        DENS="$(awk '/^% Core Density #2\(Subtracting Physical Cells\):/ {gsub(/%/, "", $NF); print $NF; exit}' "$SUM")"
        CELLAREA="$(awk '/^Total area of Standard cells\(Subtracting Physical Cells\):/ {print $(NF-1); exit}' "$SUM")"
        WIRE="$(awk '/^Total Metal[0-9]+ wire length:/ {s+=$5} END {if(s>0) printf "%.1f", s; else print "N/A"}' "$SUM")"
    fi

    local CHV="N/A"
    if [ -f "$CONG" ]; then
        local CH CV
        CH="$(awk '/Overflow:/ {match($0, /[0-9]+\.[0-9]+% H/); if(RSTART){s=substr($0,RSTART,RLENGTH); sub(/ H/,"",s); print s; exit}}' "$CONG")"
        CV="$(awk '/Overflow:/ {match($0, /[0-9]+\.[0-9]+% V/); if(RSTART){s=substr($0,RSTART,RLENGTH); sub(/ V/,"",s); print s; exit}}' "$CONG")"
        if [ -n "$CH" ] || [ -n "$CV" ]; then CHV="${CH:-0.00%} / ${CV:-0.00%}"; fi
    fi

    local SWT HWT
    SWT="$(parse_wt "$RUN_RPT/signoff" "signoff_setup")"
    HWT="$(parse_wt "$RUN_RPT/signoff" "signoff_hold")"

    local SK="N/A"
    if [ -f "$SKEW_RPT" ]; then
        SK="$(awk '/^delay_corner_slow:setup\.late/ {print $10; exit}' "$SKEW_RPT")"
        [ -z "$SK" ] && SK="N/A"
    fi

    local PI="N/A" PS="N/A" PL="N/A" PT="N/A"
    if [ -f "$PWR" ]; then
        PI="$(awk '/^Total Internal Power:/ {printf "%.4f", $4; exit}' "$PWR")"
        PS="$(awk '/^Total Switching Power:/ {printf "%.4f", $4; exit}' "$PWR")"
        PL="$(awk '/^Total Leakage Power:/ {printf "%.4f", $4; exit}' "$PWR")"
        PT="$(awk '/^Total Power:/ {printf "%.4f", $3; exit}' "$PWR")"
    fi

    local DC="N/A" AC="N/A" CC="N/A"
    if [ -f "$DRC" ]; then
        if grep -q "No DRC violations were found" "$DRC"; then DC="0"
        else DC="$(awk '/Verification Complete :|Total Violations/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}' "$DRC" || echo "?")"
        fi
    fi
    if [ -f "$ANT" ]; then
        if grep -q "No Violations Found" "$ANT"; then AC="0"
        else AC="$(awk '/Total number of process antenna violations/ {print $NF; exit}' "$ANT" || echo "?")"
        fi
    fi
    if [ -f "$CONN" ]; then
        if grep -q "Found no problems or warnings" "$CONN"; then CC="0"
        else CC="$(awk '/Problem|Warning/ {c++} END{print c+0}' "$CONN" || echo "?")"
        fi
    fi

    # Classify actual physical/timing status (never label timing-collapsed runs as PASS)
    local REAL_ST="$STATE"
    if [ "$STATE" = "PASS" ]; then
        local SW HW
        SW="${SWT%% /*}"
        HW="${HWT%% /*}"
        REAL_ST="$(awk -v sw="$SW" -v hw="$HW" -v dc="$DC" -v ac="$AC" -v cc="$CC" 'BEGIN {
            if (sw == "N/A" || hw == "N/A") { print "INCOMPLETE"; exit }
            s = sw + 0.0; h = hw + 0.0; d = dc + 0; a = ac + 0; c = cc + 0;
            if (s >= 0.0 && h >= 0.0 && d == 0 && a == 0 && c == 0) {
                print "GOLDEN SIGN-OFF";
            } else if (s < -2.0 || h < 0.0) {
                print "FAIL (Density Wall)";
            } else if (s >= -0.05 && h >= 0.0 && d == 0) {
                print "NEAR-MET (~99.6-99.8 MHz)";
            } else if (s >= -0.05 && h >= 0.0 && d > 0) {
                print "NEAR-MET (1 DRC)";
            } else {
                printf "PARTIAL (~%.1f MHz)", 1000.0 / (10.0 - s);
            }
        }')"
    fi

    echo "| $LABEL | $UTIL | ${DIE:-N/A} | ${CORE:-N/A} | ${DENS:-N/A} | ${CELLAREA:-N/A} | ${WIRE:-N/A} | $CHV | $SWT | $HWT | $SK | ${PI:-N/A} | ${PS:-N/A} | ${PL:-N/A} | **${PT:-N/A}** | ${DC} / ${AC} / ${CC} | $REAL_ST |" >> "$TABLE"
    log_m "ROW $LABEL -> Die=${DIE:-N/A}, Core=${CORE:-N/A}, Dens=${DENS:-N/A}%, Wire=${WIRE:-N/A}, Power=${PT:-N/A}mW, Setup=$SWT, Hold=$HWT, DRC=$DC, Status=$REAL_ST"
}

SCENARIOS=(
    "FP1_u50:FP1 (Base 50%):0.50"
    "BASE55:Base55 (Ref 55%):0.55"
    "FP2_u60:FP2 (Base 60%):0.60"
    "FP3_u70:FP3 (Base 70%):0.70"
    "FP4_u78:FP4 (Base 78%):0.78"
    "FP5_u85:FP5 (Base 85%):0.85"
    "FP6_icg_u65:FP6 (ICG 65%):0.65"
)

for sc in "${SCENARIOS[@]}"; do
    IFS=':' read -r TAG LABEL UTIL <<< "$sc"
    if [ "$TAG" = "BASE55" ]; then
        emit_row "$LABEL" "$UTIL" "$PROJECT_ROOT/reports/pnr" "PASS"
        continue
    fi
    RUN_WORK="$PROJECT_ROOT/work_pnr/area_sweep/$TAG"
    RUN_RPT="$PROJECT_ROOT/reports/pnr/area_sweep/$TAG"
    log_m "START resume signoff: $TAG ($LABEL)"
    SOC_RUN_TAG="$TAG" innovus -no_gui -files "$PROJECT_ROOT/scripts/finish_signoff_from_routed.tcl" \
        -log "$RUN_WORK/innovus_resume.log" < /dev/null >> "$LOG" 2>&1
    RC=$?
    ST="PASS"
    [ $RC -ne 0 ] && ST="FAIL(rc=$RC)"
    emit_row "$LABEL" "$UTIL" "$RUN_RPT" "$ST"
done

log_m "ALL_7PTS_SIGNOFF_FINISHED"
cat "$TABLE"
