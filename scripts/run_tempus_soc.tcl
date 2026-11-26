# ==============================================================================
# run_tempus_soc.tcl - True 2-View MMMC Independent Tempus STA Sign-off
# Project : Chuyen de VM1 - Physical Design Final Project
# Design  : soc_top (GPDK45: view_setup=Slow 0.9V/125C, view_hold=Fast 1.1V/0C)
# Env overrides (optional):
#   TEMPUS_NETLIST, TEMPUS_SPEF, TEMPUS_RPT_DIR, SOC_SDC, TEMPUS_DERATE (0|1)
# ==============================================================================

set DESIGN     soc_top
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SOC_ROOT   [file normalize [file join $SCRIPT_DIR ..]]
set OUT_DIR    $SOC_ROOT/outputs
set RPT        [expr {[info exists ::env(TEMPUS_RPT_DIR)] && $::env(TEMPUS_RPT_DIR) ne "" ? $::env(TEMPUS_RPT_DIR) : "$SOC_ROOT/reports/pnr/tempus"}]

if {[info exists ::env(PDK)]} {
    set PDK $::env(PDK)
} elseif {[info exists ::env(PDK_ROOT)]} {
    set PDK $::env(PDK_ROOT)
} else {
    set PDK [file join $::env(HOME) PDK_GPDK45]
}
set ::env(PDK)      $PDK
set ::env(PDK_ROOT) $PDK
set ::env(SOC_ROOT) $SOC_ROOT

file mkdir $RPT

# Prefer filler-free post-PnR netlist (avoids IMPSYC-2 warnings on physical FILL* cells)
if {[info exists ::env(TEMPUS_NETLIST)] && $::env(TEMPUS_NETLIST) ne ""} {
    set netlist $::env(TEMPUS_NETLIST)
} else {
    set netlist $OUT_DIR/${DESIGN}_pnr_lec.v
    if {![file exists $netlist]} { set netlist $OUT_DIR/${DESIGN}_final_pr.v }
    if {![file exists $netlist]} { set netlist $OUT_DIR/soc_syn.v }
}

if {[info exists ::env(TEMPUS_SPEF)] && $::env(TEMPUS_SPEF) ne ""} {
    set spef $::env(TEMPUS_SPEF)
} else {
    set spef $OUT_DIR/$DESIGN.spef
}
if {![file exists $spef]} {
    puts "WARN: $spef not found - running without parasitics (net delay = 0)"
}

set use_derate [expr {[info exists ::env(TEMPUS_DERATE)] ? $::env(TEMPUS_DERATE) : 1}]

puts ">>> (TEMPUS) MMMC 2-View setup via scripts/soc.view"
puts ">>> (TEMPUS) Netlist : $netlist"
puts ">>> (TEMPUS) SPEF    : $spef"
puts ">>> (TEMPUS) Reports : $RPT"
catch { set timing_library_read_without_power false }

read_view_definition $SOC_ROOT/scripts/soc.view
read_verilog $netlist
set_top_module $DESIGN

if {[file exists $spef]} {
    read_spef -rc_corner rc_worst $spef
    read_spef -rc_corner rc_best  $spef
}

set_interactive_constraint_modes [all_constraint_modes -active]
set_propagated_clock [all_clocks]
set_interactive_constraint_modes {}

# True intra-corner OCV + CPPR + SI-aware AAE delay calculation
if {$use_derate} {
    puts ">>> (TEMPUS) Applying intra-corner OCV derate: late=1.05, early=0.95"
    catch { set_timing_derate -late  1.05 }
    catch { set_timing_derate -early 0.95 }
} else {
    puts ">>> (TEMPUS) Running nominal (no extra OCV derate, apples-to-apples Innovus)"
}
catch { set_analysis_mode -analysisType onChipVariation -cppr both }
catch { set_delay_cal_mode -engine aae -siAware true }

update_timing -full

puts ">>> (TEMPUS) writing per-view setup/hold/viol/power reports"
report_timing -view view_setup -late  -max_paths 30 > $RPT/tempus_timing.rpt
report_timing -view view_hold  -early -max_paths 30 > $RPT/tempus_timing_hold.rpt
report_analysis_summary > $RPT/tempus_summary.rpt
report_constraint -all_violators > $RPT/tempus_viol.rpt
catch { report_power -view view_setup > $RPT/tempus_power.rpt }
if {![file exists $RPT/tempus_power.rpt] || [file size $RPT/tempus_power.rpt] == 0} {
    catch { report_power > $RPT/tempus_power.rpt }
}

puts "=============================================================="
puts ">>> TEMPUS MMMC 2-VIEW DONE. Reports: $RPT"
puts "=============================================================="
exit
