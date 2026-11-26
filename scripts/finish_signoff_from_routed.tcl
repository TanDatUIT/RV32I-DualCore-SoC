# ==============================================================================
# finish_signoff_from_routed.tcl - Resume Innovus Step 7 Sign-off from routed.enc
# ==============================================================================
set DESIGN     soc_top
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SOC_ROOT   [file normalize [file join $SCRIPT_DIR ..]]

set RUN_TAG ""
if {[info exists ::env(SOC_RUN_TAG)] && $::env(SOC_RUN_TAG) ne ""} {
    set RUN_TAG $::env(SOC_RUN_TAG)
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

file mkdir $OUT_DIR
file mkdir $RPT_ROOT/signoff

setMultiCpuUsage -localCpu 1
restoreDesign $DBS/routed.enc.dat $DESIGN

setExtractRCMode -engine postRoute -effortLevel low
extractRC
rcOut -spef $OUT_DIR/$DESIGN.spef

if {[catch { setDelayCalMode -engine aae -SIAware true } err]} {
    catch { setDelayCalMode -engine aae -SIAware false }
}
setAnalysisMode -analysisType onChipVariation -cppr both

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

saveDesign $DBS/signoff.enc
puts ">>> SIGNOFF RESUME DONE (RUN_TAG=$RUN_TAG)"
exit
