# ==============================================================================
# eco_fp6_golden.tcl - Post-Route ECO on FP6_icg_u65 to close -3 ps Setup + 1 DRC
# Restores routed.enc.dat (before filler) or signoff.enc.dat, fixes DRV/Setup/Hold
# and Metal1 ParallelRunLength DRC, then exports clean Golden Sign-off deliverables.
# ==============================================================================
set DESIGN     soc_top
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SOC_ROOT   [file normalize [file join $SCRIPT_DIR ..]]
set RUN_TAG    [expr {[info exists ::env(SOC_RUN_TAG)] && $::env(SOC_RUN_TAG) ne "" ? $::env(SOC_RUN_TAG) : "FP6_icg_u65"}]

set WORK     $SOC_ROOT/work_pnr/area_sweep/$RUN_TAG
set DBS      $WORK/DBS
set OUT_DIR  $SOC_ROOT/outputs/area_sweep/$RUN_TAG
set RPT_ROOT $SOC_ROOT/reports/pnr/area_sweep/$RUN_TAG

if {[info exists ::env(PDK)]} {
    set PDK_ROOT $::env(PDK)
} elseif {[info exists ::env(PDK_ROOT)]} {
    set PDK_ROOT $::env(PDK_ROOT)
} else {
    set PDK_ROOT [file join $::env(HOME) PDK_GPDK45]
}
set ::env(PDK)      $PDK_ROOT
set ::env(PDK_ROOT) $PDK_ROOT
set ::env(SOC_ROOT) $SOC_ROOT
set ::env(SOC_SDC)  $SOC_ROOT/outputs/soc_syn_icg.sdc

file mkdir $OUT_DIR
file mkdir $RPT_ROOT/route
file mkdir $RPT_ROOT/signoff

setMultiCpuUsage -localCpu 1

puts ">>> (ECO) Restoring $DBS/routed.enc.dat for $RUN_TAG"
restoreDesign $DBS/routed.enc.dat $DESIGN

# Remove physical fillers before ECO cell sizing / buffering
catch { deleteFiller -prefix FILL }

setExtractRCMode -engine postRoute -effortLevel low
if {[catch { setDelayCalMode -engine aae -SIAware true } err]} {
    catch { setDelayCalMode -engine aae -SIAware false }
}
setAnalysisMode -analysisType onChipVariation -cppr both

puts ">>> (ECO) Post-Route DRV + Setup + Hold optimization"
optDesign -postRoute -drv -outDir $RPT_ROOT/signoff -prefix eco_drv
optDesign -postRoute -setup -outDir $RPT_ROOT/signoff -prefix eco_setup
optDesign -postRoute -hold  -outDir $RPT_ROOT/signoff -prefix eco_hold

puts ">>> (ECO) Fixing Metal1 DRC with ecoRoute"
setNanoRouteMode -droutePostRouteSwapVia multiCut
setNanoRouteMode -drouteFixAntenna true
ecoRoute -fix_drc

# Save filler-free netlist for LEC & GLS BEFORE re-adding fillers
saveNetlist $OUT_DIR/${DESIGN}_pnr_lec.v

puts ">>> (ECO) Re-adding physical fillers"
addFiller -cell {FILL64 FILL32 FILL16 FILL8 FILL4 FILL2 FILL1} -prefix FILL -doDRC true
ecoRoute -fix_drc

puts ">>> (ECO) Physical Sign-off Verification (DRC / Antenna / Connectivity)"
verify_drc -limit 1000 -report $RPT_ROOT/route/drc_fixed.rpt
verifyProcessAntenna -report $RPT_ROOT/route/antenna.rpt
verifyConnectivity -type all -error 1000 -warning 50 -report $RPT_ROOT/route/connectivity.rpt

puts ">>> (ECO) RC Extraction + Final 2-Corner Sign-off Timing & Power"
extractRC
rcOut -spef $OUT_DIR/$DESIGN.spef

timeDesign -postRoute -pathReports -drvReports -slackReports -numPaths 50 \
    -prefix signoff_setup -outDir $RPT_ROOT/signoff
timeDesign -postRoute -hold -pathReports -slackReports -numPaths 50 \
    -prefix signoff_hold  -outDir $RPT_ROOT/signoff

summaryReport -noHtml -outfile $RPT_ROOT/signoff/design_summary.rpt
reportDensity > $RPT_ROOT/signoff/density.rpt
report_power  -outfile $RPT_ROOT/signoff/power.rpt
report_constraint -all_violators > $RPT_ROOT/signoff/constraint_violators.rpt

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

saveDesign $DBS/signoff_eco.enc
puts "=============================================================="
puts ">>> ECO GOLDEN SIGNOFF DONE ($RUN_TAG)"
puts "=============================================================="
exit
