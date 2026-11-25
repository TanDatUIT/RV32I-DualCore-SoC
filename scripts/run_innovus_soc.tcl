# ==============================================================================
# run_innovus_soc.tcl - Innovus RTL-to-GDSII flow for the RV32I SoC
# Project : Physical Design Final Project
# Tech    : Cadence GPDK 45nm
# Design  : soc_top (RV32I + 2x sram_2k_macro + Mini-NPU + DMA + Periph/Sec)
#
# Usage (from <project_root>/):
#     innovus -no_gui -files scripts/run_innovus_soc.tcl
# ==============================================================================

set DESIGN     soc_top
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SOC_ROOT   [file normalize [file join $SCRIPT_DIR ..]]

set RUN_TAG ""
if {[info exists ::env(SOC_RUN_TAG)] && $::env(SOC_RUN_TAG) ne ""} {
    set RUN_TAG $::env(SOC_RUN_TAG)
}

set TARGET_UTIL 0.55
if {[info exists ::env(SOC_UTIL)] && $::env(SOC_UTIL) ne ""} {
    set TARGET_UTIL $::env(SOC_UTIL)
}

if {$RUN_TAG ne ""} {
    set WORK     $SOC_ROOT/work_pnr/area_sweep/$RUN_TAG
    set DBS      $WORK/DBS
    set OUT_DIR  $SOC_ROOT/outputs/area_sweep/$RUN_TAG
    set RPT_ROOT $SOC_ROOT/reports/pnr/area_sweep/$RUN_TAG
} else {
    set WORK     $SOC_ROOT/work_pnr
    set DBS      $WORK/DBS
    set OUT_DIR  $SOC_ROOT/outputs
    set RPT_ROOT $SOC_ROOT/reports/pnr
}

set NETLIST_IN $SOC_ROOT/outputs/soc_syn.v
if {[info exists ::env(SOC_NETLIST)] && $::env(SOC_NETLIST) ne ""} {
    set NETLIST_IN $::env(SOC_NETLIST)
}

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
set ::env(SOC_ROOT) $SOC_ROOT

foreach d [list $WORK $DBS $OUT_DIR \
                $RPT_ROOT/floorplan $RPT_ROOT/placement $RPT_ROOT/cts \
                $RPT_ROOT/route $RPT_ROOT/signoff] {
    file mkdir $d
}

if {![file exists $NETLIST_IN]} {
    error "Missing $NETLIST_IN - run scripts/run_genus_soc.tcl first"
}

puts "=============================================================="
puts "\[innovus\] SOC_ROOT    = $SOC_ROOT"
puts "\[innovus\] PDK_ROOT    = $PDK_ROOT"
puts "\[innovus\] RUN_TAG     = $RUN_TAG"
puts "\[innovus\] TARGET_UTIL = $TARGET_UTIL"
puts "\[innovus\] NETLIST_IN  = $NETLIST_IN"
puts "=============================================================="

setMultiCpuUsage -localCpu 1   ;# licence is 1 CPU on EDA server

# ------------------------------------------------------------------------------
# 1. init_design (2-corner MMMC: Slow Setup + Fast Hold)
# ------------------------------------------------------------------------------
set init_verilog   $NETLIST_IN
set init_top_cell  $DESIGN
set init_lef_file  [list \
    $PDK_ROOT/lef/gsclib045_tech.lef \
    $PDK_ROOT/lef/gsclib045_macro.lef \
    $PDK_ROOT/lef/sram_2k_macro.lef]
set init_mmmc_file $SOC_ROOT/scripts/soc.view
set init_pwr_net   VDD
set init_gnd_net   VSS

init_design
report_clocks

# ------------------------------------------------------------------------------
# 2. Floorplan: die/core + Dual-SRAM Hard Macro Placement
# ------------------------------------------------------------------------------
# Target utilisation (default 0.55; overridable via SOC_UTIL for Faraday PPA sweep)
floorPlan -site CoreSite -r 1.0 $TARGET_UTIL 15 15 15 15

set core_box [dbGet top.fPlan.coreBox]
while {[llength $core_box] == 1 && [llength [lindex $core_box 0]] > 1} {
    set core_box [lindex $core_box 0]
}
set core_x1 [lindex $core_box 0]
set core_y1 [lindex $core_box 1]
set core_x2 [lindex $core_box 2]
set core_y2 [lindex $core_box 3]
puts "\[innovus\] core box = $core_x1 $core_y1 $core_x2 $core_y2"

# Each sram_2k_macro is 80 x 100 um with signal pins on bottom edge (Metal3).
# Place I-SRAM at Top-Left and D-SRAM at Top-Right (both R0 facing core).
set MACRO_W 80.0
set MACRO_H 100.0

set macro_ptrs [dbGet -p2 top.insts.cell.name sram_2k_macro]
if {[llength $macro_ptrs] == 0} {
    error "No sram_2k_macro instances found in netlist"
}

set core_w [expr {$core_x2 - $core_x1}]
set idx 0
foreach ptr $macro_ptrs {
    set m_name [dbGet $ptr.name]
    set my [expr {$core_y2 - 10.0 - $MACRO_H}]
    if {[llength $macro_ptrs] >= 2} {
        if {[string match "*isram*" $m_name] || ($idx == 0 && ![string match "*dsram*" $m_name])} {
            set mx [expr {$core_x1 + 10.0}]
        } else {
            set mx [expr {$core_x2 - 10.0 - $MACRO_W}]
            if {$core_w < [expr {2.0 * $MACRO_W + 30.0}]} {
                # Narrow core fallback: place D-SRAM Bottom-Right to avoid overlap
                set my [expr {$core_y1 + 10.0}]
            }
        }
    } else {
        set mx [expr {$core_x1 + 10.0}]
    }
    # Snap to CoreSite grid (0.2 x 1.71)
    set mx [expr {round($mx / 0.2)  * 0.2}]
    set my [expr {round($my / 1.71) * 1.71}]

    placeInstance $m_name [list $mx $my] R0 -fixed
    addHaloToBlock 8 8 8 8 $m_name
    createPlaceBlockage -type hard \
        -box [list $mx $my [expr {$mx + $MACRO_W}] [expr {$my + $MACRO_H}]] \
        -name "SRAM_MACRO_BLOCK_$idx"
    puts "\[innovus\] Macro #$idx ($m_name) placed at ($mx, $my) R0 with 8um halo"
    incr idx
}

# I/O pins spread across all 4 edges on Metal3
editPin -pin {i_clk i_resetn i_uart_rxd o_uart_txd o_wdt_rst} -edge 0 -spreadType SIDE -layer 3
editPin -pin {i_gpio_in[*]}                                   -edge 1 -spreadType SIDE -layer 3
editPin -pin {o_gpio_out[*] o_gpio_oe[*]}                     -edge 2 -spreadType SIDE -layer 3
editPin -pin {o_spi_sclk o_spi_mosi i_spi_miso o_spi_cs_n}    -edge 3 -spreadType SIDE -layer 3

saveDesign $DBS/floorplan.enc

# ------------------------------------------------------------------------------
# 3. Power planning (PDN)
# ------------------------------------------------------------------------------
clearGlobalNets
globalNetConnect VDD -type pgpin -pin VDD -inst * -override
globalNetConnect VSS -type pgpin -pin VSS -inst * -override
globalNetConnect VDD -type tiehi -inst * -override
globalNetConnect VSS -type tielo -inst * -override

# 3a. Core ring on top two thick metals (Metal10 vertical / Metal11 horizontal)
addRing -nets {VDD VSS} -type core_rings -follow core \
    -layer {top Metal11 bottom Metal11 left Metal10 right Metal10} \
    -width 3.0 -spacing 1.5 -offset 2.0

# 3b. Dedicated block rings around both SRAM macros
addRing -nets {VDD VSS} -type block_rings -around each_block \
    -layer {top Metal5 bottom Metal5 left Metal6 right Metal6} \
    -width 2.0 -spacing 1.0 -offset 1.5

# 3c. Orthogonal Power Stripes: Metal8 vertical, Metal9 horizontal
setAddStripeMode -stacked_via_top_layer Metal11
setAddStripeMode -stacked_via_bottom_layer Metal8
addStripe -nets {VDD VSS} -layer Metal8 -direction vertical \
    -width 1.0 -spacing 0.6 -set_to_set_distance 25.0 \
    -start_from left -start_offset 12.0 \
    -stacked_via_top_layer Metal11 -stacked_via_bottom_layer Metal7

addStripe -nets {VDD VSS} -layer Metal9 -direction horizontal \
    -width 1.0 -spacing 0.6 -set_to_set_distance 25.0 \
    -start_from bottom -start_offset 12.0

# 3d. Standard-cell followpins + macro pin power connections
sroute -connect {corePin blockPin floatingStripe} \
    -layerChangeRange {Metal1 Metal11} \
    -corePinTarget {firstAfterRowEnd} \
    -blockPinTarget {nearestTarget} \
    -floatingStripeTarget {ring} \
    -allowJogging 1 -allowLayerChange 1 \
    -crossoverViaLayerRange {Metal1 Metal11} \
    -nets {VDD VSS}

verifyConnectivity -type special -error 1000 -warning 50 \
    -report $RPT_ROOT/floorplan/pdn_connectivity.rpt
verify_drc -limit 1000 -report $RPT_ROOT/floorplan/pdn_drc.rpt

saveDesign $DBS/powerplan.enc

# ------------------------------------------------------------------------------
# 4. Placement & Pre-CTS Opt
# ------------------------------------------------------------------------------
setPlaceMode -place_design_floorplan_mode false
setPlaceMode -place_global_cong_effort high
setPlaceMode -place_global_timing_effort high
setPlaceMode -place_detail_wire_length_opt_effort medium

place_opt_design

checkPlace -verbose > $RPT_ROOT/placement/checkPlace.rpt
reportCongestion -overflow > $RPT_ROOT/placement/congestion.rpt
timeDesign -preCTS -expandedViews -outDir $RPT_ROOT/placement -prefix prects

saveDesign $DBS/placement.enc

# ------------------------------------------------------------------------------
# 5. Clock Tree Synthesis (CCOpt) & Post-CTS Closure
# ------------------------------------------------------------------------------
catch { set_ccopt_property target_skew 0.08 }
catch { set_ccopt_property -net_type trunk target_max_trans 0.12 }

create_ccopt_clock_tree_spec
ccopt_design

report_ccopt_clock_trees -file $RPT_ROOT/cts/clock_trees.rpt
report_ccopt_skew_groups   -file $RPT_ROOT/cts/skew_groups.rpt

optDesign -postCTS
timeDesign -postCTS -outDir $RPT_ROOT/cts -prefix postcts_setup
optDesign -postCTS -hold
timeDesign -postCTS -hold -outDir $RPT_ROOT/cts -prefix postcts_hold

checkPlace -verbose > $RPT_ROOT/cts/checkPlace.rpt
saveDesign $DBS/cts.enc

# ------------------------------------------------------------------------------
# 6. NanoRoute (Timing + SI Driven) & Post-Route Closure
# ------------------------------------------------------------------------------
setAnalysisMode -analysisType onChipVariation -cppr both
setNanoRouteMode -quiet -routeWithTimingDriven true
setNanoRouteMode -quiet -routeWithSiDriven true
setNanoRouteMode -quiet -routeSiEffort high
setNanoRouteMode -quiet -drouteFixAntenna true
setNanoRouteMode -quiet -drouteEndIteration 20

routeDesign

optDesign -postRoute
optDesign -postRoute -hold
catch { optDesign -postRoute -drv }

# Export LEC-friendly netlist BEFORE inserting physical filler cells
saveNetlist $OUT_DIR/${DESIGN}_pnr_lec.v

addFiller -cell {FILL64 FILL32 FILL16 FILL8 FILL4 FILL2 FILL1} -prefix FILLER

verify_drc -limit 1000 -report $RPT_ROOT/route/drc.rpt
if {[catch { ecoRoute -fix_drc } err]} {
    puts "WARN: ecoRoute -fix_drc failed: $err"
}
verify_drc -limit 1000 -report $RPT_ROOT/route/drc_fixed.rpt
verifyConnectivity -type all -report $RPT_ROOT/route/connectivity.rpt
verifyProcessAntenna -reportfile $RPT_ROOT/route/antenna.rpt -error 1000

timeDesign -postRoute      -outDir $RPT_ROOT/route -prefix postroute_setup
timeDesign -postRoute -hold -outDir $RPT_ROOT/route -prefix postroute_hold

saveDesign $DBS/routed.enc

# ------------------------------------------------------------------------------
# 7. Sign-off: RC Extraction, SPEF, OCV+SI STA, Rail Check, GDSII
# ------------------------------------------------------------------------------
setExtractRCMode -engine postRoute -effortLevel low
extractRC
rcOut -spef $OUT_DIR/$DESIGN.spef

if {[catch { setDelayCalMode -engine aae -SIAware true } err]} {
    puts "WARN: SI-aware AAE unavailable ($err), falling back to non-SI AAE"
    catch { setDelayCalMode -engine aae -SIAware false }
}
setAnalysisMode -analysisType onChipVariation -cppr both

timeDesign -postRoute -pathReports -drvReports -slackReports -numPaths 50 \
    -prefix signoff_setup -outDir $RPT_ROOT/signoff
timeDesign -postRoute -hold -pathReports -drvReports -slackReports -numPaths 50 \
    -prefix signoff_hold  -outDir $RPT_ROOT/signoff

summaryReport -noHtml -outfile $RPT_ROOT/signoff/design_summary.rpt
reportDensity > $RPT_ROOT/signoff/density.rpt
report_power  -outfile $RPT_ROOT/signoff/power.rpt
report_constraint -all_violators > $RPT_ROOT/signoff/constraint_violators.rpt

if {[catch {
    set_default_switching_activity -input_activity 0.1 -global_activity 0.1
    set_power_analysis_mode -method static
    set_rail_analysis_mode -method static -accuracy hd
    analyze_rail VDD -type net -output $RPT_ROOT/signoff/rail_analysis
} err]} {
    puts "WARN: IR-drop/rail analysis unavailable: $err (GPDK45 lacks .cl)"
}

# Physical netlist (with fillers) for GLS + DEF + GDSII
catch {
    saveNetlist $OUT_DIR/${DESIGN}_final_pr.v \
        -includePhysicalCell {FILL64 FILL32 FILL16 FILL8 FILL4 FILL2 FILL1}
}
if {![file exists $OUT_DIR/${DESIGN}_final_pr.v]} {
    saveNetlist $OUT_DIR/${DESIGN}_final_pr.v
}
defOut -floorplan -netlist -routing $OUT_DIR/${DESIGN}_final.def
catch { write_sdf $OUT_DIR/${DESIGN}.sdf }

set map_file $PDK_ROOT/gpdk045.map
if {![file exists $map_file]} { set map_file $PDK_ROOT/streamOut.map }
streamOut $OUT_DIR/$DESIGN.gds \
    -mapFile $map_file -libName DesignLib -structureName $DESIGN \
    -mode ALL -units 2000

saveDesign $DBS/signoff.enc

puts "=============================================================="
puts ">>> INNOVUS DONE"
puts ">>> Netlist (GLS) : $OUT_DIR/${DESIGN}_final_pr.v"
puts ">>> Netlist (LEC) : $OUT_DIR/${DESIGN}_pnr_lec.v"
puts ">>> SPEF          : $OUT_DIR/$DESIGN.spef"
puts ">>> SDF           : $OUT_DIR/$DESIGN.sdf"
puts ">>> DEF           : $OUT_DIR/${DESIGN}_final.def"
puts ">>> GDSII         : $OUT_DIR/$DESIGN.gds"
puts ">>> Reports       : $RPT_ROOT"
puts "=============================================================="
exit
