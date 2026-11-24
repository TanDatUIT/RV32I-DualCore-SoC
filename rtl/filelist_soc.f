// =============================================================================
// filelist_soc.f - SoC RTL file list for synthesis & simulation
// -----------------------------------------------------------------------------
// NOTE: the SRAM hard macro model (sim/sram_2k_macro.v) is intentionally NOT
// listed here. Synthesis resolves sram_2k_macro from a technology/FPGA RAM wrapper, and
// behavioural model must not be synthesised.
// =============================================================================

// RISC-V RV32I core
rtl/rv32i/rv32i_alu.v
rtl/rv32i/rv32i_regfile.v
rtl/rv32i/rv32i_core.v

// System bus / interconnect
rtl/bus/soc_bus.v

// Memory subsystem (adapts the 1RW hard macro to byte-enable stores)
rtl/mem/sram_ctrl.v

// Hardware accelerator (Mini-NPU: 4x4 systolic MAC + post-proc) & DMA
rtl/accel/pe.v
rtl/accel/accelerator_top.v
rtl/accel/accel_wrapper.v
rtl/dma/soc_dma.v

// Peripherals & Security / Lifecycle
rtl/periph/soc_timer.v
rtl/periph/soc_uart.v
rtl/periph/soc_gpio.v
rtl/periph/soc_crc32.v
rtl/periph/soc_spi.v
rtl/periph/soc_sysctrl.v

// Top level
rtl/soc_top.v
