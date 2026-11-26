// =============================================================================
// run_lec.do - Cadence Conformal LEC (Golden RTL vs Gate-Level Netlist)
// Usage (from project root):
//   lec -xl -nogui -dofile scripts/run_lec.do
//   LEC_REVISED=outputs/soc_top_pnr_lec.v LEC_LOG=reports/lec/lec_rtl2pnr.log \
//     lec -xl -nogui -dofile scripts/run_lec.do
// =============================================================================

tclmode
set pdk_dir [expr {[info exists ::env(PDK)] ? $::env(PDK) : "$::env(HOME)/PDK_GPDK45"}]
set rev_net [expr {[info exists ::env(LEC_REVISED)] ? $::env(LEC_REVISED) : "outputs/soc_syn.v"}]
set log_out [expr {[info exists ::env(LEC_LOG)] ? $::env(LEC_LOG) : "reports/lec/lec_soc.log"}]
file mkdir [file dirname $log_out]
vpx set log file "$log_out" -replace
// Blackbox SRAM hard macro BEFORE reading library/design
vpx add notranslate module sram_2k_macro -both
// 1. Read Liberty technology & macro libraries
vpx read library -liberty -both "$pdk_dir/lib/slow_vdd1v0_basiccells.lib" "$pdk_dir/lib/sram_2k_macro.lib"
vpxmode

// 2. Read Golden RTL (Verilog-2001)
read design -verilog2k -golden \
    rtl/rv32i/rv32i_alu.v \
    rtl/rv32i/rv32i_regfile.v \
    rtl/rv32i/rv32i_core.v \
    rtl/bus/soc_bus.v \
    rtl/mem/sram_ctrl.v \
    rtl/accel/pe.v \
    rtl/accel/accelerator_top.v \
    rtl/accel/accel_wrapper.v \
    rtl/dma/soc_dma.v \
    rtl/periph/soc_timer.v \
    rtl/periph/soc_uart.v \
    rtl/periph/soc_gpio.v \
    rtl/periph/soc_crc32.v \
    rtl/periph/soc_spi.v \
    rtl/periph/soc_sysctrl.v \
    rtl/soc_top.v

// 3. Read Revised Netlist (Post-Syn or Post-PnR without fillers)
tclmode
vpx read design -verilog -revised "$rev_net"
vpxmode

set root module soc_top -both

// 4. Modeling directives matching Genus sequential & clock-gating optimizations
set undriven signal 0 -golden
set flatten model -seq_constant -seq_constant_x_to 0
set flatten model -seq_merge
set flatten model -gated_clock
set analyze option -auto

// 5. Switch to LEC mode, analyze setup and compare
set system mode lec
analyze datapath -module -verbose
add compare points -all
compare

report compare data -summary
report compare data -class nonequivalent
report unmapped points -summary

exit -f
