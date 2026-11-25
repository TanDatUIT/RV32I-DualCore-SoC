# ==============================================================================
# soc.sdc - Timing constraints for the RV32I SoC (soc_top)
# Project : Physical Design Final Project (Cadence GPDK 45nm)
# ------------------------------------------------------------------------------
# Single clock domain on port `i_clk`.
#   default 100 MHz (10.0 ns)   -> requirement f >= 50 MHz
#   125 MHz (8.0 ns)            -> export SOC_CLK_PERIOD=8.0
#   150 MHz (6.667 ns)          -> export SOC_CLK_PERIOD=6.667
#   200 MHz (5.0 ns)            -> export SOC_CLK_PERIOD=5.0
# ==============================================================================

set_units -time ns -capacitance pF

# ------------------------------------------------------------------------------
# 1. Clock definition
# ------------------------------------------------------------------------------
if {[info exists ::env(SOC_CLK_PERIOD)]} {
    set SOC_PERIOD $::env(SOC_CLK_PERIOD)
} else {
    set SOC_PERIOD 10.0
}
set SOC_HALF [expr {$SOC_PERIOD / 2.0}]

create_clock -name clk -period $SOC_PERIOD -waveform [list 0.0 $SOC_HALF] \
    [get_ports i_clk]

# ------------------------------------------------------------------------------
# 2. Clock quality
# ------------------------------------------------------------------------------
set_clock_uncertainty -setup [expr {$SOC_PERIOD * 0.015}] [get_clocks clk]
set_clock_uncertainty -hold  [expr {$SOC_PERIOD * 0.005}] [get_clocks clk]

set_clock_transition 0.08 [get_clocks clk]

catch { set_clock_latency -source 0.50 [get_clocks clk] }
catch { set_clock_latency          0.30 [get_clocks clk] }

# ------------------------------------------------------------------------------
# 3. Input / output delays (peripheral & system interfaces)
# ------------------------------------------------------------------------------
set_input_delay  -clock clk -max 1.00 [get_ports i_uart_rxd]
set_input_delay  -clock clk -min 0.20 [get_ports i_uart_rxd]
set_output_delay -clock clk -max 1.00 [get_ports o_uart_txd]
set_output_delay -clock clk -min 0.20 [get_ports o_uart_txd]

set_input_delay  -clock clk -max 1.00 [get_ports {i_gpio_in[*]}]
set_input_delay  -clock clk -min 0.20 [get_ports {i_gpio_in[*]}]
set_output_delay -clock clk -max 1.00 [get_ports {o_gpio_out[*]}]
set_output_delay -clock clk -min 0.20 [get_ports {o_gpio_out[*]}]
set_output_delay -clock clk -max 1.00 [get_ports {o_gpio_oe[*]}]
set_output_delay -clock clk -min 0.20 [get_ports {o_gpio_oe[*]}]

set_input_delay  -clock clk -max 1.00 [get_ports i_spi_miso]
set_input_delay  -clock clk -min 0.20 [get_ports i_spi_miso]
set_output_delay -clock clk -max 1.00 [get_ports {o_spi_sclk o_spi_mosi o_spi_cs_n}]
set_output_delay -clock clk -min 0.20 [get_ports {o_spi_sclk o_spi_mosi o_spi_cs_n}]

set_output_delay -clock clk -max 1.00 [get_ports o_wdt_rst]
set_output_delay -clock clk -min 0.20 [get_ports o_wdt_rst]

# Asynchronous reset, synchronised outside core
set_false_path -from [get_ports i_resetn]

# ------------------------------------------------------------------------------
# 4. Drive strength and load of external pins
# ------------------------------------------------------------------------------
set_driving_cell -lib_cell INVX2 -pin Y \
    [remove_from_collection [all_inputs] [get_ports i_clk]]
set_load 0.05 [all_outputs]

# ------------------------------------------------------------------------------
# 5. Library design rules
# ------------------------------------------------------------------------------
set_max_transition  0.28 [current_design]
set_max_capacitance 0.25 [current_design]
set_max_fanout      32   [current_design]
