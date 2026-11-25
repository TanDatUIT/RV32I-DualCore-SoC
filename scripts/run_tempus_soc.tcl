# ==============================================================================
# run_tempus_soc.tcl - Two-Corner Independent Tempus STA Sign-off
# Project : Physical Design Final Project
# Design  : soc_top (GPDK45: Slow 0.9V/125C Setup + Fast 1.1V/0C Hold)
# ==============================================================================

set DESIGN     soc_top
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SOC_ROOT   [file normalize [file join $SCRIPT_DIR ..]]
set OUT_DIR    $SOC_ROOT/outputs
set RPT        $SOC_ROOT/reports/pnr/tempus

if {[info exists ::env(PDK)]} {
    set PDK $::env(PDK)
} elseif {[info exists ::env(PDK_ROOT)]} {
    set PDK $::env(PDK_ROOT)
} else {
    set PDK [file join $::env(HOME) PDK_GPDK45]
}

file mkdir $RPT

set netlist $OUT_DIR/${DESIGN}_final_pr.v
if {![file exists $netlist]} { set netlist $OUT_DIR/${DESIGN}_pnr_lec.v }
if {![file exists $netlist]} { set netlist $OUT_DIR/soc_syn.v }

set spef $OUT_DIR/$DESIGN.spef
if {![file exists $spef]} {
    puts "WARN: $spef not found - running without parasitics (net delay = 0)"
}

puts ">>> (TEMPUS) reading slow (max) and fast (min) libraries"
read_lib -max [list $PDK/lib/slow_vdd1v0_basiccells.lib $PDK/lib/sram_2k_macro.lib]
read_lib -min [list $PDK/lib/fast_vdd1v0_basicCells.lib $PDK/lib/sram_2k_macro.lib]

puts ">>> (TEMPUS) netlist + set_top_module + SDC + SPEF"
read_verilog $netlist
set_top_module $DESIGN
read_sdc $SOC_ROOT/sdc/soc.sdc
if {[file exists $spef]} {
    read_spef $spef
}

set_propagated_clock [all_clocks]

# Sign-off OCV derating, CPPR and SI-aware delay calculation
catch { set_timing_derate -late  1.05 }
catch { set_timing_derate -early 0.95 }
catch { set_analysis_mode -analysisType onChipVariation -cppr both }
catch { set_delay_cal_mode -engine aae -siAware true }

update_timing

puts ">>> (TEMPUS) writing setup/hold/viol/power reports"
report_timing -late  -max_paths 30 > $RPT/tempus_timing.rpt
report_timing -early -max_paths 30 > $RPT/tempus_timing_hold.rpt
report_constraint -all_violators   > $RPT/tempus_viol.rpt
catch { report_power > $RPT/tempus_power.rpt }

puts "=============================================================="
puts ">>> TEMPUS DONE. Reports: $RPT"
puts "=============================================================="
exit
