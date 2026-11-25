# ==============================================================================
# run_genus_soc.tcl - Genus synthesis for the RV32I SoC (soc_top)
# Project : Physical Design Final Project
# Tech    : Cadence GPDK 45nm (slow_vdd1v0_basiccells + sram_2k_macro)
# Usage   : genus -no_gui -files scripts/run_genus_soc.tcl
# Env vars:
#   SOC_CLK_PERIOD : clock period in ns (default 10.0 = 100 MHz)
#   SOC_ENABLE_ICG : set to 1 to insert ICG clock gating (TLATNTSCAX*)
# ==============================================================================

set DESIGN soc_top

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SOC_ROOT   [file normalize [file join $SCRIPT_DIR ..]]
set WORK_SYN   $SOC_ROOT/work_syn
set OUT_DIR    $SOC_ROOT/outputs
set RPT_DIR    $SOC_ROOT/reports/syn

if {![file exists [file join $SOC_ROOT rtl filelist_soc.f]]} {
    error "Cannot find rtl/filelist_soc.f from SOC_ROOT=$SOC_ROOT"
}

file mkdir $WORK_SYN
file mkdir $OUT_DIR
file mkdir $RPT_DIR

if {[info exists ::env(PDK)]} {
    set PDK_ROOT $::env(PDK)
} elseif {[info exists ::env(PDK_ROOT)]} {
    set PDK_ROOT $::env(PDK_ROOT)
} elseif {[file exists [file join $::env(HOME) PDK_GPDK45]]} {
    set PDK_ROOT [file join $::env(HOME) PDK_GPDK45]
} else {
    set PDK_ROOT $::env(HOME)/PDK_GPDK45
}
set ::env(PDK)      $PDK_ROOT
set ::env(PDK_ROOT) $PDK_ROOT

if {[info exists ::env(SOC_CLK_PERIOD)]} {
    set SOC_PERIOD $::env(SOC_CLK_PERIOD)
} else {
    set SOC_PERIOD 10.0
}
set SOC_FREQ [format %.1f [expr {1000.0 / $SOC_PERIOD}]]

set ENABLE_ICG 0
if {[info exists ::env(SOC_ENABLE_ICG)] && $::env(SOC_ENABLE_ICG) eq "1"} {
    set ENABLE_ICG 1
}

puts "\[genus\] SOC_ROOT   = $SOC_ROOT"
puts "\[genus\] PDK_ROOT   = $PDK_ROOT"
puts "\[genus\] CLOCK      = $SOC_FREQ MHz ($SOC_PERIOD ns)"
puts "\[genus\] ENABLE_ICG = $ENABLE_ICG"

# ------------------------------------------------------------------------------
# 1. Libraries and RTL
# ------------------------------------------------------------------------------
set_db / .init_lib_search_path [list $PDK_ROOT/lib]
set_db / .init_hdl_search_path [list $SOC_ROOT]
catch { set_db / .super_thread_servers "" }
catch { set_db / .auto_super_thread false }
catch { set_db / .max_cpus 1 }
catch { set_db / .max_cpus_per_server 1 }

read_libs [list \
    $PDK_ROOT/lib/slow_vdd1v0_basiccells.lib \
    $PDK_ROOT/lib/sram_2k_macro.lib]

if {$ENABLE_ICG} {
    catch { set_db [get_lib_cells TLATNTSCAX*] .dont_use false }
    catch { set_db [get_lib_cells TLATNCAX*]   .dont_use false }
    set_db / .lp_insert_clock_gating true
}

# Read the file list, skipping comments and blank lines
set fp [open [file join $SOC_ROOT rtl filelist_soc.f] r]
set hdl_files {}
while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line eq ""} { continue }
    if {[string match "//*" $line] || [string match "#*" $line]} { continue }
    lappend hdl_files [file join $SOC_ROOT $line]
}
close $fp
puts "\[genus\] RTL files: [llength $hdl_files]"

read_hdl -language v2001 $hdl_files
elaborate $DESIGN
check_design -unresolved

# ------------------------------------------------------------------------------
# 2. Constraints & Directives
# ------------------------------------------------------------------------------
read_sdc [file join $SOC_ROOT sdc soc.sdc]

# Ideal network on async reset prevents buffer tree bloating
catch { set_db [get_nets -of_objects [get_ports i_resetn]] .ideal_network true }

# Protect both sram_2k_macro hard macro instances
catch { set_dont_touch [get_cells -hier *sram_macro*] true }

# ------------------------------------------------------------------------------
# 3. Synthesis: generic -> mapped -> optimised
# ------------------------------------------------------------------------------
set_db / .syn_generic_effort high
set_db / .syn_map_effort high
set_db / .syn_opt_effort high
catch { set_db / .syn_opt_area_effort high }
catch { set_db / .syn_opt_tns_effort high }
catch { set_db / .boundary_optimization true }
catch { set_db / .resource_sharing true }

syn_generic
syn_map
syn_opt

# ------------------------------------------------------------------------------
# 4. Netlist Cleanup (Eliminate assign statements for Innovus handoff)
# ------------------------------------------------------------------------------
catch { set_db / .remove_assigns true }
catch { remove_assigns_without_optimization }
catch { set_db write_vlog_unconnected_port_style none }

# ------------------------------------------------------------------------------
# 5. Reports
# ------------------------------------------------------------------------------
catch { redirect [file join $RPT_DIR area.rpt]           { report_area -detail } }
catch { redirect [file join $RPT_DIR timing.rpt]         { report_timing -max_paths 20 } }
if {[catch { redirect [file join $RPT_DIR timing_summary.rpt] { report_timing -summary } }]} {
    catch { redirect [file join $RPT_DIR timing_summary.rpt] { report_timing -max_paths 20 } }
}
catch { redirect [file join $RPT_DIR timing_lint.rpt]    { report_timing -lint } }
catch { redirect [file join $RPT_DIR qor.rpt]            { report_qor } }
catch { redirect [file join $RPT_DIR power.rpt]          { report_power } }
catch { redirect [file join $RPT_DIR gates.rpt]          { report_gates } }
catch { redirect [file join $RPT_DIR check.rpt]          { check_design -all } }
catch { redirect [file join $RPT_DIR messages.rpt]       { report_messages } }
if {$ENABLE_ICG} {
    catch { redirect [file join $RPT_DIR clock_gating.rpt] { report_clock_gating } }
}

# ------------------------------------------------------------------------------
# 6. Netlist + SDC + handoff files
# ------------------------------------------------------------------------------
set out_v   [file join $OUT_DIR soc_syn.v]
set out_sdc [file join $OUT_DIR soc_syn.sdc]

write_hdl -mapped > $out_v
write_sdc > $out_sdc

# Remove Genus-injected "-library slow_vdd1v0" on set_driving_cell so the
# exported SDC works across both slow (setup) and fast (hold) MMMC corners.
set sdc_in [open $out_sdc r]
set sdc_txt [read $sdc_in]
close $sdc_in
regsub -all -- {-library\s+slow_vdd1v0\s+} $sdc_txt "" sdc_txt
set sdc_out [open $out_sdc w]
puts -nonewline $sdc_out $sdc_txt
close $sdc_out

if {$ENABLE_ICG} {
    file copy -force $out_v   [file join $OUT_DIR soc_syn_icg.v]
    file copy -force $out_sdc [file join $OUT_DIR soc_syn_icg.sdc]
}

redirect [file join $RPT_DIR synthesis_summary.rpt] {
    puts "=============================================================="
    puts " SYNTHESIS SUMMARY - $DESIGN (GPDK45, slow 0.9V 125C)"
    puts "=============================================================="
    puts "Clock target : $SOC_FREQ MHz (period $SOC_PERIOD ns) | ICG=$ENABLE_ICG"
    puts ""
    report_area
    puts ""
    report_timing -max_paths 5
}

puts "=============================================================="
puts ">>> GENUS DONE: $out_v"
puts ">>> Reports   : $RPT_DIR"
puts "=============================================================="
exit
