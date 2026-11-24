# ==============================================================================
# run_vivado_impl.tcl - Vivado 2022.2 Out-Of-Context Post-Route Implementation
# Target Design : soc_top (Dual-Core RV32I SoC, Final_Project_SoC_datdat)
# Target Part   : xck26-sfvc784-2LV-c (Kria KV260) @ 100 MHz
# Usage         : vivado -mode batch -nojournal -log vivado_impl.log \
#                 -source ../../scripts/run_vivado_impl.tcl
# ==============================================================================

set target_part "xck26-sfvc784-2LV-c"
set top_module  "soc_top"

set script_dir [file normalize [file dirname [info script]]]
set proj_root  [file normalize [file join $script_dir ".."]]
set out_dir    [file join $proj_root "reports" "vivado"]

file mkdir $out_dir

puts "=============================================================================="
puts " Vivado Out-Of-Context Post-Route Impl : $top_module"
puts " Project Root                          : $proj_root"
puts " Target Part                           : $target_part"
puts " Report Dir                            : $out_dir"
puts "=============================================================================="

create_project -in_memory -part $target_part

# Read Verilog-2001 RTL list strictly (no -sv)
set flist_file [file join $proj_root "rtl" "filelist_soc.f"]
if {![file exists $flist_file]} {
    puts "ERROR: Filelist not found at $flist_file"
    exit 1
}

set fp [open $flist_file r]
set lines [split [read $fp] "\n"]
close $fp

foreach line $lines {
    set trimmed [string trim $line]
    if {$trimmed ne "" && ![string match "//*" $trimmed]} {
        set full_path [file normalize [file join $proj_root $trimmed]]
        if {![file exists $full_path]} {
            puts "ERROR: Source file not found: $full_path"
            exit 1
        }
        read_verilog $full_path
    }
}

set sram_model [file join $script_dir "vivado_sram_2k_synth.v"]
if {![file exists $sram_model]} {
    puts "ERROR: Vivado SRAM model not found: $sram_model"
    exit 1
}
read_verilog $sram_model

# Constraints (OOC 100 MHz + uncertainty + false_path async reset; no pad I/O delays in OOC)
set xdc_file [file join $out_dir "soc_vivado_impl.xdc"]
set xdc_fp [open $xdc_file w]
puts $xdc_fp "# Auto-generated temporary Vivado OOC impl constraints (100 MHz)"
puts $xdc_fp "create_clock -name clk -period 10.000 \[get_ports i_clk\]"
puts $xdc_fp "set_clock_uncertainty -setup 0.150 \[get_clocks clk\]"
puts $xdc_fp "set_clock_uncertainty -hold  0.050 \[get_clocks clk\]"
puts $xdc_fp "set_false_path -from \[get_ports i_resetn\]"
close $xdc_fp
read_xdc $xdc_file

puts "\[VIVADO-IMPL\] Running synth_design -mode out_of_context..."
synth_design -top $top_module -part $target_part -mode out_of_context

# Attach HD.CLK_SRC on OOC clock port to eliminate Timing 38-242 and model real clock tree skew
set clk_site [lindex [get_sites -quiet BUFGCE*] 0]
if {$clk_site ne ""} {
    puts "\[VIVADO-IMPL\] Assigning HD.CLK_SRC = $clk_site on i_clk"
    set_property HD.CLK_SRC $clk_site [get_ports i_clk]
}

puts "\[VIVADO-IMPL\] Running opt_design -> place_design -> phys_opt_design -> route_design..."
opt_design
place_design
phys_opt_design
route_design

puts "\[VIVADO-IMPL\] Writing post-route implementation reports to $out_dir..."
report_utilization    -file [file join $out_dir "impl_utilization.rpt"]
report_timing_summary -max_paths 10 -file [file join $out_dir "impl_timing_summary.rpt"]
check_timing -verbose -file [file join $out_dir "impl_check_timing.rpt"]
report_power          -file [file join $out_dir "impl_power.rpt"]
report_drc            -file [file join $out_dir "impl_drc.rpt"]
report_route_status   -file [file join $out_dir "impl_route_status.rpt"]

puts "\[VIVADO-IMPL\] NOTE: impl_timing_summary.rpt reflects OOC register-to-register timing (no external pad I/O delays without IOBUFs)."
puts "\[VIVADO-IMPL\] Post-Route Implementation completed successfully."
exit 0
