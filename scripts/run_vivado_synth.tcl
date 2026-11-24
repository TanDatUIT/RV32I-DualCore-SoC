# ==============================================================================
# run_vivado_synth.tcl - Vivado 2022.2 Batch Synthesis (synth-only, OOC)
# Target Design : soc_top (Final_Project_SoC_datdat)
# Target Part   : xck26-sfvc784-2LV-c (Kria KV260)
# Usage         : vivado -mode batch -nojournal -log vivado_synth.log \
#                 -source ../../scripts/run_vivado_synth.tcl
# ==============================================================================

set target_part "xck26-sfvc784-2LV-c"
set top_module  "soc_top"

set script_dir [file normalize [file dirname [info script]]]
set proj_root  [file normalize [file join $script_dir ".."]]
set out_dir    [file join $proj_root "reports" "vivado"]

file mkdir $out_dir

puts "=============================================================================="
puts " Vivado Out-Of-Context Synthesis : $top_module"
puts " Project Root                    : $proj_root"
puts " Target Part                     : $target_part"
puts " Report Dir                      : $out_dir"
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

puts "\[VIVADO-SYNTH\] Reading Verilog-2001 RTL from $flist_file..."
foreach line $lines {
    set trimmed [string trim $line]
    if {$trimmed ne "" && ![string match "//*" $trimmed]} {
        set full_path [file normalize [file join $proj_root $trimmed]]
        if {![file exists $full_path]} {
            puts "ERROR: Source file not found: $full_path"
            exit 1
        }
        puts "  + read_verilog $full_path"
        read_verilog $full_path
    }
}

# Read Vivado-only synthesizable BRAM behavioral model for sram_2k_macro
set sram_model [file join $script_dir "vivado_sram_2k_synth.v"]
if {![file exists $sram_model]} {
    puts "ERROR: Vivado SRAM model not found: $sram_model"
    exit 1
}
puts "  + read_verilog $sram_model"
read_verilog $sram_model

# Generate temporary XDC in out_dir (keep sdc/ untouched)
set xdc_file [file join $out_dir "soc_vivado.xdc"]
set xdc_fp [open $xdc_file w]
puts $xdc_fp "# Auto-generated temporary Vivado OOC constraints (100 MHz)"
puts $xdc_fp "create_clock -name clk -period 10.000 \[get_ports i_clk\]"
puts $xdc_fp "set_clock_uncertainty -setup 0.150 \[get_clocks clk\]"
puts $xdc_fp "set_clock_uncertainty -hold  0.050 \[get_clocks clk\]"
puts $xdc_fp "set_false_path -from \[get_ports i_resetn\]"
puts $xdc_fp "set_input_delay  -clock clk -max 1.00 \[get_ports {i_uart_rxd i_gpio_in\[*\] i_spi_miso}\]"
puts $xdc_fp "set_input_delay  -clock clk -min 0.20 \[get_ports {i_uart_rxd i_gpio_in\[*\] i_spi_miso}\]"
puts $xdc_fp "set_output_delay -clock clk -max 1.00 \[get_ports {o_uart_txd o_gpio_out\[*\] o_gpio_oe\[*\] o_spi_sclk o_spi_mosi o_spi_cs_n o_wdt_rst}\]"
puts $xdc_fp "set_output_delay -clock clk -min 0.20 \[get_ports {o_uart_txd o_gpio_out\[*\] o_gpio_oe\[*\] o_spi_sclk o_spi_mosi o_spi_cs_n o_wdt_rst}\]"
close $xdc_fp

puts "\[VIVADO-SYNTH\] Reading constraints from $xdc_file..."
read_xdc $xdc_file

# Run OOC synthesis
puts "\[VIVADO-SYNTH\] Running synth_design -top $top_module -part $target_part -mode out_of_context..."
synth_design -top $top_module -part $target_part -mode out_of_context

# Export reports
puts "\[VIVADO-SYNTH\] Writing reports to $out_dir..."
report_utilization -file [file join $out_dir "utilization.rpt"]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $out_dir "utilization_hier.rpt"]
report_timing_summary -max_paths 10 -file [file join $out_dir "timing_summary.rpt"]
check_timing -verbose -file [file join $out_dir "check_timing.rpt"]
report_high_fanout_nets -max_nets 15 -file [file join $out_dir "high_fanout.rpt"]

puts "\[VIVADO-SYNTH\] Synthesis completed successfully."
exit 0
