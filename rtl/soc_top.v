// =============================================================================
// Module      : soc_top
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : Top-level Dual-Core RV32I SoC for RTL-to-GDSII & UVM.
//
//   * Master CPU0 : rv32i_core (5-stage RV32I, Hart ID 0, reset PC 0x0000_0000)
//   * Master CPU1 : rv32i_core (5-stage RV32I, Hart ID 1, programmable boot PC)
//   * Master DMA  : soc_dma (32-bit word transfer engine, ID 2)
//   * Interconnect: soc_bus (Dual-Channel Harvard + 3-Master Round-Robin)
//   * Memory      : 2x sram_2k_macro (4KB Shared I-SRAM + 4KB Shared D-SRAM)
//   * Mini-NPU    : 4x4 systolic MAC array + ReLU/shift/INT8 clamp post-proc
//   * Security    : HW CRC32 (IEEE 802.3) + Boot Write-Lock + Watchdog Timer
//   * SMP / IPC   : HART_ID, Atomic HW Spinlock, Bidirectional Mailbox
//   * Peripherals : Timer, UART (8N1), GPIO (16-bit), SPI Master (4 modes)
//   * Perf Mon    : Hardware MCYCLE / MINSTRET0 / MINSTRET1 in soc_sysctrl
//
// Clock domain  : single `i_clk` (100 MHz target)
// Reset         : asynchronous, active-low `i_resetn`
// =============================================================================
`default_nettype none

module soc_top #(
    parameter integer PR_UART_CLKS_PER_BIT = 868
)(
    input  wire        i_clk,
    input  wire        i_resetn,

    // UART
    input  wire        i_uart_rxd,
    output wire        o_uart_txd,

    // GPIO
    input  wire [15:0] i_gpio_in,
    output wire [15:0] o_gpio_out,
    output wire [15:0] o_gpio_oe,

    // SPI Master
    output wire        o_spi_sclk,
    output wire        o_spi_mosi,
    input  wire        i_spi_miso,
    output wire        o_spi_cs_n,

    // Watchdog reset observation pulse
    output wire        o_wdt_rst
);

    // CPU0 <-> bus
    wire        w_cpu0_imem_req;
    wire [31:0] w_cpu0_imem_addr;
    wire [31:0] w_cpu0_imem_rdata;
    wire        w_cpu0_imem_ready;

    wire        w_cpu0_dmem_req;
    wire        w_cpu0_dmem_we;
    wire [3:0]  w_cpu0_dmem_be;
    wire [31:0] w_cpu0_dmem_addr;
    wire [31:0] w_cpu0_dmem_wdata;
    wire [31:0] w_cpu0_dmem_rdata;
    wire        w_cpu0_dmem_ready;
    wire        w_instr_retired0;

    // CPU1 <-> bus
    wire        w_cpu1_imem_req;
    wire [31:0] w_cpu1_imem_addr;
    wire [31:0] w_cpu1_imem_rdata;
    wire        w_cpu1_imem_ready;

    wire        w_cpu1_dmem_req;
    wire        w_cpu1_dmem_we;
    wire [3:0]  w_cpu1_dmem_be;
    wire [31:0] w_cpu1_dmem_addr;
    wire [31:0] w_cpu1_dmem_wdata;
    wire [31:0] w_cpu1_dmem_rdata;
    wire        w_cpu1_dmem_ready;
    wire        w_instr_retired1;

    // DMA master <-> bus
    wire        w_dma_m_req;
    wire        w_dma_m_we;
    wire [3:0]  w_dma_m_be;
    wire [31:0] w_dma_m_addr;
    wire [31:0] w_dma_m_wdata;
    wire [31:0] w_dma_m_rdata;
    wire        w_dma_m_ready;

    // Security / lifecycle / SMP control wires
    wire        w_boot_lock;
    wire        w_boot_lock_viol;
    wire        w_wdt_rst;
    wire        w_core1_rst;
    wire [31:0] w_core1_boot_pc;
    wire [1:0]  w_sys_master_id;

    // Bus <-> slaves
    wire        w_isram_req;
    wire        w_isram_we;
    wire [3:0]  w_isram_be;
    wire [11:0] w_isram_addr;
    wire [31:0] w_isram_wdata;
    wire [31:0] w_isram_rdata;
    wire        w_isram_ready;

    wire        w_dsram_req;
    wire        w_dsram_we;
    wire [3:0]  w_dsram_be;
    wire [11:0] w_dsram_addr;
    wire [31:0] w_dsram_wdata;
    wire [31:0] w_dsram_rdata;
    wire        w_dsram_ready;

    wire        w_accel_req;
    wire        w_accel_we;
    wire [7:0]  w_accel_addr;
    wire [31:0] w_accel_wdata;
    wire [31:0] w_accel_rdata;
    wire        w_accel_ready;

    wire        w_dmacfg_req;
    wire        w_dmacfg_we;
    wire [7:0]  w_dmacfg_addr;
    wire [31:0] w_dmacfg_wdata;
    wire [31:0] w_dmacfg_rdata;
    wire        w_dmacfg_ready;

    wire        w_timer_req;
    wire        w_timer_we;
    wire [4:0]  w_timer_addr;
    wire [31:0] w_timer_wdata;
    wire [31:0] w_timer_rdata;
    wire        w_timer_ready;

    wire        w_uart_req;
    wire        w_uart_we;
    wire [4:0]  w_uart_addr;
    wire [31:0] w_uart_wdata;
    wire [31:0] w_uart_rdata;
    wire        w_uart_ready;

    wire        w_gpio_req;
    wire        w_gpio_we;
    wire [4:0]  w_gpio_addr;
    wire [31:0] w_gpio_wdata;
    wire [31:0] w_gpio_rdata;
    wire        w_gpio_ready;

    wire        w_crc_req;
    wire        w_crc_we;
    wire [4:0]  w_crc_addr;
    wire [31:0] w_crc_wdata;
    wire [31:0] w_crc_rdata;
    wire        w_crc_ready;

    wire        w_spi_req;
    wire        w_spi_we;
    wire [4:0]  w_spi_addr;
    wire [31:0] w_spi_wdata;
    wire [31:0] w_spi_rdata;
    wire        w_spi_ready;

    wire        w_sys_req;
    wire        w_sys_we;
    wire [5:0]  w_sys_addr;
    wire [31:0] w_sys_wdata;
    wire [31:0] w_sys_rdata;
    wire        w_sys_ready;

    assign o_wdt_rst = w_wdt_rst;

    // -------------------------------------------------------------------------
    // Master 0: RV32I CPU0 (Hart 0 - primary boot core)
    // -------------------------------------------------------------------------
    rv32i_core u_cpu0 (
        .i_clk           (i_clk),
        .i_resetn        (i_resetn),
        .i_soft_rst      (w_wdt_rst),
        .i_boot_pc       (32'd0),
        .o_imem_req      (w_cpu0_imem_req),
        .o_imem_addr     (w_cpu0_imem_addr),
        .i_imem_rdata    (w_cpu0_imem_rdata),
        .i_imem_ready    (w_cpu0_imem_ready),
        .o_dmem_req      (w_cpu0_dmem_req),
        .o_dmem_we       (w_cpu0_dmem_we),
        .o_dmem_be       (w_cpu0_dmem_be),
        .o_dmem_addr     (w_cpu0_dmem_addr),
        .o_dmem_wdata    (w_cpu0_dmem_wdata),
        .i_dmem_rdata    (w_cpu0_dmem_rdata),
        .i_dmem_ready    (w_cpu0_dmem_ready),
        .o_instr_retired (w_instr_retired0)
    );

    // -------------------------------------------------------------------------
    // Master 1: RV32I CPU1 (Hart 1 - secondary worker core)
    // -------------------------------------------------------------------------
    rv32i_core u_cpu1 (
        .i_clk           (i_clk),
        .i_resetn        (i_resetn),
        .i_soft_rst      (w_core1_rst),
        .i_boot_pc       (w_core1_boot_pc),
        .o_imem_req      (w_cpu1_imem_req),
        .o_imem_addr     (w_cpu1_imem_addr),
        .i_imem_rdata    (w_cpu1_imem_rdata),
        .i_imem_ready    (w_cpu1_imem_ready),
        .o_dmem_req      (w_cpu1_dmem_req),
        .o_dmem_we       (w_cpu1_dmem_we),
        .o_dmem_be       (w_cpu1_dmem_be),
        .o_dmem_addr     (w_cpu1_dmem_addr),
        .o_dmem_wdata    (w_cpu1_dmem_wdata),
        .i_dmem_rdata    (w_cpu1_dmem_rdata),
        .i_dmem_ready    (w_cpu1_dmem_ready),
        .o_instr_retired (w_instr_retired1)
    );

    // -------------------------------------------------------------------------
    // System Bus (Dual-Channel Harvard + 3-Master Round-Robin Arbiter)
    // -------------------------------------------------------------------------
    soc_bus u_bus (
        .i_clk            (i_clk),
        .i_resetn         (i_resetn),
        .i_cpu0_soft_rst  (w_wdt_rst),
        .i_cpu1_soft_rst  (w_core1_rst),
        .i_dma_soft_rst   (w_wdt_rst),
        .i_imem0_req      (w_cpu0_imem_req),
        .i_imem0_addr     (w_cpu0_imem_addr),
        .o_imem0_rdata    (w_cpu0_imem_rdata),
        .o_imem0_ready    (w_cpu0_imem_ready),
        .i_imem1_req      (w_cpu1_imem_req),
        .i_imem1_addr     (w_cpu1_imem_addr),
        .o_imem1_rdata    (w_cpu1_imem_rdata),
        .o_imem1_ready    (w_cpu1_imem_ready),
        .i_dmem0_req      (w_cpu0_dmem_req),
        .i_dmem0_we       (w_cpu0_dmem_we),
        .i_dmem0_be       (w_cpu0_dmem_be),
        .i_dmem0_addr     (w_cpu0_dmem_addr),
        .i_dmem0_wdata    (w_cpu0_dmem_wdata),
        .o_dmem0_rdata    (w_cpu0_dmem_rdata),
        .o_dmem0_ready    (w_cpu0_dmem_ready),
        .i_dmem1_req      (w_cpu1_dmem_req),
        .i_dmem1_we       (w_cpu1_dmem_we),
        .i_dmem1_be       (w_cpu1_dmem_be),
        .i_dmem1_addr     (w_cpu1_dmem_addr),
        .i_dmem1_wdata    (w_cpu1_dmem_wdata),
        .o_dmem1_rdata    (w_cpu1_dmem_rdata),
        .o_dmem1_ready    (w_cpu1_dmem_ready),
        .i_dma_req        (w_dma_m_req),
        .i_dma_we         (w_dma_m_we),
        .i_dma_be         (w_dma_m_be),
        .i_dma_addr       (w_dma_m_addr),
        .i_dma_wdata      (w_dma_m_wdata),
        .o_dma_rdata      (w_dma_m_rdata),
        .o_dma_ready      (w_dma_m_ready),
        .i_boot_lock      (w_boot_lock),
        .o_boot_lock_viol (w_boot_lock_viol),
        .o_isram_req      (w_isram_req),
        .o_isram_we       (w_isram_we),
        .o_isram_be       (w_isram_be),
        .o_isram_addr     (w_isram_addr),
        .o_isram_wdata    (w_isram_wdata),
        .i_isram_rdata    (w_isram_rdata),
        .i_isram_ready    (w_isram_ready),
        .o_dsram_req      (w_dsram_req),
        .o_dsram_we       (w_dsram_we),
        .o_dsram_be       (w_dsram_be),
        .o_dsram_addr     (w_dsram_addr),
        .o_dsram_wdata    (w_dsram_wdata),
        .i_dsram_rdata    (w_dsram_rdata),
        .i_dsram_ready    (w_dsram_ready),
        .o_accel_req      (w_accel_req),
        .o_accel_we       (w_accel_we),
        .o_accel_addr     (w_accel_addr),
        .o_accel_wdata    (w_accel_wdata),
        .i_accel_rdata    (w_accel_rdata),
        .i_accel_ready    (w_accel_ready),
        .o_dmacfg_req     (w_dmacfg_req),
        .o_dmacfg_we      (w_dmacfg_we),
        .o_dmacfg_addr    (w_dmacfg_addr),
        .o_dmacfg_wdata   (w_dmacfg_wdata),
        .i_dmacfg_rdata   (w_dmacfg_rdata),
        .i_dmacfg_ready   (w_dmacfg_ready),
        .o_timer_req      (w_timer_req),
        .o_timer_we       (w_timer_we),
        .o_timer_addr     (w_timer_addr),
        .o_timer_wdata    (w_timer_wdata),
        .i_timer_rdata    (w_timer_rdata),
        .i_timer_ready    (w_timer_ready),
        .o_uart_req       (w_uart_req),
        .o_uart_we        (w_uart_we),
        .o_uart_addr      (w_uart_addr),
        .o_uart_wdata     (w_uart_wdata),
        .i_uart_rdata     (w_uart_rdata),
        .i_uart_ready     (w_uart_ready),
        .o_gpio_req       (w_gpio_req),
        .o_gpio_we        (w_gpio_we),
        .o_gpio_addr      (w_gpio_addr),
        .o_gpio_wdata     (w_gpio_wdata),
        .i_gpio_rdata     (w_gpio_rdata),
        .i_gpio_ready     (w_gpio_ready),
        .o_crc_req        (w_crc_req),
        .o_crc_we         (w_crc_we),
        .o_crc_addr       (w_crc_addr),
        .o_crc_wdata      (w_crc_wdata),
        .i_crc_rdata      (w_crc_rdata),
        .i_crc_ready      (w_crc_ready),
        .o_spi_req        (w_spi_req),
        .o_spi_we         (w_spi_we),
        .o_spi_addr       (w_spi_addr),
        .o_spi_wdata      (w_spi_wdata),
        .i_spi_rdata      (w_spi_rdata),
        .i_spi_ready      (w_spi_ready),
        .o_sys_req        (w_sys_req),
        .o_sys_we         (w_sys_we),
        .o_sys_addr       (w_sys_addr),
        .o_sys_wdata      (w_sys_wdata),
        .o_sys_master_id  (w_sys_master_id),
        .i_sys_rdata      (w_sys_rdata),
        .i_sys_ready      (w_sys_ready)
    );

    // -------------------------------------------------------------------------
    // Dual-SRAM Memory Subsystem: 4 KB Shared I-SRAM + 4 KB Shared D-SRAM
    // -------------------------------------------------------------------------
    sram_ctrl u_isram_ctrl (
        .i_clk    (i_clk),
        .i_resetn (i_resetn),
        .i_req    (w_isram_req),
        .i_we     (w_isram_we),
        .i_be     (w_isram_be),
        .i_addr   (w_isram_addr),
        .i_wdata  (w_isram_wdata),
        .o_rdata  (w_isram_rdata),
        .o_ready  (w_isram_ready)
    );

    sram_ctrl u_dsram_ctrl (
        .i_clk    (i_clk),
        .i_resetn (i_resetn),
        .i_req    (w_dsram_req),
        .i_we     (w_dsram_we),
        .i_be     (w_dsram_be),
        .i_addr   (w_dsram_addr),
        .i_wdata  (w_dsram_wdata),
        .o_rdata  (w_dsram_rdata),
        .o_ready  (w_dsram_ready)
    );

    // -------------------------------------------------------------------------
    // Mini-NPU Accelerator (4x4 Systolic + Post-Processing)
    // -------------------------------------------------------------------------
    accel_wrapper u_accel (
        .i_clk    (i_clk),
        .i_resetn (i_resetn),
        .i_req    (w_accel_req),
        .i_we     (w_accel_we),
        .i_addr   (w_accel_addr),
        .i_wdata  (w_accel_wdata),
        .o_rdata  (w_accel_rdata),
        .o_ready  (w_accel_ready)
    );

    // -------------------------------------------------------------------------
    // Master 2 / Slave 3: DMA Controller
    // -------------------------------------------------------------------------
    soc_dma u_dma (
        .i_clk       (i_clk),
        .i_resetn    (i_resetn),
        .i_soft_rst  (w_wdt_rst),
        .i_req       (w_dmacfg_req),
        .i_we        (w_dmacfg_we),
        .i_addr      (w_dmacfg_addr),
        .i_wdata     (w_dmacfg_wdata),
        .o_rdata     (w_dmacfg_rdata),
        .o_ready     (w_dmacfg_ready),
        .o_dma_req   (w_dma_m_req),
        .o_dma_we    (w_dma_m_we),
        .o_dma_be    (w_dma_m_be),
        .o_dma_addr  (w_dma_m_addr),
        .o_dma_wdata (w_dma_m_wdata),
        .i_dma_rdata (w_dma_m_rdata),
        .i_dma_ready (w_dma_m_ready)
    );

    // -------------------------------------------------------------------------
    // Peripherals & Security / SMP Subsystem
    // -------------------------------------------------------------------------
    soc_timer u_timer (
        .i_clk    (i_clk),
        .i_resetn (i_resetn),
        .i_req    (w_timer_req),
        .i_we     (w_timer_we),
        .i_addr   (w_timer_addr),
        .i_wdata  (w_timer_wdata),
        .o_rdata  (w_timer_rdata),
        .o_ready  (w_timer_ready)
    );

    soc_uart #(
        .PR_CLKS_PER_BIT (PR_UART_CLKS_PER_BIT)
    ) u_uart (
        .i_clk      (i_clk),
        .i_resetn   (i_resetn),
        .i_req      (w_uart_req),
        .i_we       (w_uart_we),
        .i_addr     (w_uart_addr),
        .i_wdata    (w_uart_wdata),
        .o_rdata    (w_uart_rdata),
        .o_ready    (w_uart_ready),
        .i_uart_rxd (i_uart_rxd),
        .o_uart_txd (o_uart_txd)
    );

    soc_gpio u_gpio (
        .i_clk      (i_clk),
        .i_resetn   (i_resetn),
        .i_req      (w_gpio_req),
        .i_we       (w_gpio_we),
        .i_addr     (w_gpio_addr),
        .i_wdata    (w_gpio_wdata),
        .o_rdata    (w_gpio_rdata),
        .o_ready    (w_gpio_ready),
        .i_gpio_in  (i_gpio_in),
        .o_gpio_out (o_gpio_out),
        .o_gpio_oe  (o_gpio_oe)
    );

    soc_crc32 u_crc (
        .i_clk    (i_clk),
        .i_resetn (i_resetn),
        .i_req    (w_crc_req),
        .i_we     (w_crc_we),
        .i_addr   (w_crc_addr),
        .i_wdata  (w_crc_wdata),
        .o_rdata  (w_crc_rdata),
        .o_ready  (w_crc_ready)
    );

    soc_spi u_spi (
        .i_clk      (i_clk),
        .i_resetn   (i_resetn),
        .i_req      (w_spi_req),
        .i_we       (w_spi_we),
        .i_addr     (w_spi_addr),
        .i_wdata    (w_spi_wdata),
        .o_rdata    (w_spi_rdata),
        .o_ready    (w_spi_ready),
        .o_spi_sclk (o_spi_sclk),
        .o_spi_mosi (o_spi_mosi),
        .i_spi_miso (i_spi_miso),
        .o_spi_cs_n (o_spi_cs_n)
    );

    soc_sysctrl u_sysctrl (
        .i_clk            (i_clk),
        .i_resetn         (i_resetn),
        .i_req            (w_sys_req),
        .i_we             (w_sys_we),
        .i_addr           (w_sys_addr),
        .i_wdata          (w_sys_wdata),
        .i_master_id      (w_sys_master_id),
        .o_rdata          (w_sys_rdata),
        .o_ready          (w_sys_ready),
        .i_boot_lock_viol (w_boot_lock_viol),
        .i_instr_retired  (w_instr_retired0),
        .i_instr_retired1 (w_instr_retired1),
        .o_boot_lock      (w_boot_lock),
        .o_wdt_rst        (w_wdt_rst),
        .o_core1_rst      (w_core1_rst),
        .o_core1_boot_pc  (w_core1_boot_pc)
    );

endmodule

`default_nettype wire
