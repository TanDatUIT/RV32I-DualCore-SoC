// =============================================================================
// Module      : soc_bus
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : Dual-channel Harvard interconnect with 3-master Round-Robin
//               arbiters (CPU0, CPU1, DMA) and boot-region write protection.
//
//               Channel 1 (I-SRAM fast path): Round-Robin between CPU0 I-Fetch
//               and CPU1 I-Fetch; yields cleanly to D-Bus when targeting I-SRAM
//               (bootloader writes / rodata reads).
//               Channel 2 (Data/MMIO arbiter): 3-master fair Round-Robin
//               between CPU0 D-Bus (ID 0), CPU1 D-Bus (ID 1), and DMA (ID 2).
//
//               Memory map (byte addresses)
//                 0x0000_0000 - 0x0000_0FFF : I-SRAM 4 KB (Boot region 0x000-0x1FF)
//                 0x0000_1000 - 0x0000_1FFF : D-SRAM 4 KB
//                 0x1000_0000 - 0x1000_00FF : Mini-NPU Accelerator MMIO
//                 0x1000_0100 - 0x1000_01FF : DMA Controller MMIO
//                 0x2000_0000 - 0x2000_00FF : Timer
//                 0x2000_0100 - 0x2000_01FF : UART
//                 0x2000_0200 - 0x2000_02FF : GPIO
//                 0x2000_0300 - 0x2000_03FF : HW CRC32
//                 0x2000_0400 - 0x2000_04FF : SPI Master
//                 0x2000_0500 - 0x2000_05FF : SysCtrl (Boot-Lock, WDT, Perf, SMP)
// =============================================================================
`default_nettype none

module soc_bus (
    input  wire        i_clk,
    input  wire        i_resetn,
    input  wire        i_cpu0_soft_rst,
    input  wire        i_cpu1_soft_rst,
    input  wire        i_dma_soft_rst,

    // Master 0A: CPU0 instruction fetch
    input  wire        i_imem0_req,
    input  wire [31:0] i_imem0_addr,
    output wire [31:0] o_imem0_rdata,
    output wire        o_imem0_ready,

    // Master 1A: CPU1 instruction fetch
    input  wire        i_imem1_req,
    input  wire [31:0] i_imem1_addr,
    output wire [31:0] o_imem1_rdata,
    output wire        o_imem1_ready,

    // Master 0B: CPU0 load/store (Master ID = 2'd0)
    input  wire        i_dmem0_req,
    input  wire        i_dmem0_we,
    input  wire [3:0]  i_dmem0_be,
    input  wire [31:0] i_dmem0_addr,
    input  wire [31:0] i_dmem0_wdata,
    output reg  [31:0] o_dmem0_rdata,
    output reg         o_dmem0_ready,

    // Master 1B: CPU1 load/store (Master ID = 2'd1)
    input  wire        i_dmem1_req,
    input  wire        i_dmem1_we,
    input  wire [3:0]  i_dmem1_be,
    input  wire [31:0] i_dmem1_addr,
    input  wire [31:0] i_dmem1_wdata,
    output reg  [31:0] o_dmem1_rdata,
    output reg         o_dmem1_ready,

    // Master 2: DMA engine (Master ID = 2'd2)
    input  wire        i_dma_req,
    input  wire        i_dma_we,
    input  wire [3:0]  i_dma_be,
    input  wire [31:0] i_dma_addr,
    input  wire [31:0] i_dma_wdata,
    output reg  [31:0] o_dma_rdata,
    output reg         o_dma_ready,

    // Security control
    input  wire        i_boot_lock,
    output reg         o_boot_lock_viol,

    // Slave 0: I-SRAM
    output reg         o_isram_req,
    output reg         o_isram_we,
    output reg  [3:0]  o_isram_be,
    output reg  [11:0] o_isram_addr,
    output reg  [31:0] o_isram_wdata,
    input  wire [31:0] i_isram_rdata,
    input  wire        i_isram_ready,

    // Slave 1: D-SRAM
    output wire        o_dsram_req,
    output wire        o_dsram_we,
    output wire [3:0]  o_dsram_be,
    output wire [11:0] o_dsram_addr,
    output wire [31:0] o_dsram_wdata,
    input  wire [31:0] i_dsram_rdata,
    input  wire        i_dsram_ready,

    // Slave 2: Mini-NPU Accelerator
    output wire        o_accel_req,
    output wire        o_accel_we,
    output wire [7:0]  o_accel_addr,
    output wire [31:0] o_accel_wdata,
    input  wire [31:0] i_accel_rdata,
    input  wire        i_accel_ready,

    // Slave 3: DMA Slave Registers
    output wire        o_dmacfg_req,
    output wire        o_dmacfg_we,
    output wire [7:0]  o_dmacfg_addr,
    output wire [31:0] o_dmacfg_wdata,
    input  wire [31:0] i_dmacfg_rdata,
    input  wire        i_dmacfg_ready,

    // Slave 4: Timer
    output wire        o_timer_req,
    output wire        o_timer_we,
    output wire [4:0]  o_timer_addr,
    output wire [31:0] o_timer_wdata,
    input  wire [31:0] i_timer_rdata,
    input  wire        i_timer_ready,

    // Slave 5: UART
    output wire        o_uart_req,
    output wire        o_uart_we,
    output wire [4:0]  o_uart_addr,
    output wire [31:0] o_uart_wdata,
    input  wire [31:0] i_uart_rdata,
    input  wire        i_uart_ready,

    // Slave 6: GPIO
    output wire        o_gpio_req,
    output wire        o_gpio_we,
    output wire [4:0]  o_gpio_addr,
    output wire [31:0] o_gpio_wdata,
    input  wire [31:0] i_gpio_rdata,
    input  wire        i_gpio_ready,

    // Slave 7: HW CRC32
    output wire        o_crc_req,
    output wire        o_crc_we,
    output wire [4:0]  o_crc_addr,
    output wire [31:0] o_crc_wdata,
    input  wire [31:0] i_crc_rdata,
    input  wire        i_crc_ready,

    // Slave 8: SPI Master
    output wire        o_spi_req,
    output wire        o_spi_we,
    output wire [4:0]  o_spi_addr,
    output wire [31:0] o_spi_wdata,
    input  wire [31:0] i_spi_rdata,
    input  wire        i_spi_ready,

    // Slave 9: SysCtrl (includes active Data-bus master ID sideband)
    output wire        o_sys_req,
    output wire        o_sys_we,
    output wire [5:0]  o_sys_addr,
    output wire [31:0] o_sys_wdata,
    output wire [1:0]  o_sys_master_id,
    input  wire [31:0] i_sys_rdata,
    input  wire        i_sys_ready
);

    localparam [1:0] LP_IS_IDLE  = 2'd0;
    localparam [1:0] LP_IS_IMEM0 = 2'd1;
    localparam [1:0] LP_IS_IMEM1 = 2'd2;
    localparam [1:0] LP_IS_DBUS  = 2'd3;

    localparam [1:0] LP_D_IDLE = 2'd0;
    localparam [1:0] LP_D_WAIT = 2'd1;
    localparam [1:0] LP_D_RESP = 2'd2;

    localparam [1:0] LP_M_CPU0 = 2'd0;
    localparam [1:0] LP_M_CPU1 = 2'd1;
    localparam [1:0] LP_M_DMA  = 2'd2;

    reg [1:0]  reg_isram_state;
    reg        reg_imem_rr;     // 0 = prefer CPU0 next, 1 = prefer CPU1 next
    reg        reg_isram_drop;  // suppress orphan I-SRAM ready if master soft-reset

    reg [1:0]  reg_d_state;
    reg [1:0]  reg_d_master;    // active master on Data/MMIO channel
    reg [1:0]  reg_d_rr_ptr;    // round-robin priority pointer
    reg        reg_d_drop;      // suppress orphan D-Bus ready if master soft-reset
    reg [31:0] reg_d_addr;
    reg        reg_d_we;
    reg [3:0]  reg_d_be;
    reg [31:0] reg_d_wdata;
    reg [31:0] reg_d_rdata;

    // -------------------------------------------------------------------------
    // Data/MMIO address decode (registered address)
    // -------------------------------------------------------------------------
    wire w_sel_isram  = (reg_d_addr[31:12] == 20'h00000);
    wire w_sel_dsram  = (reg_d_addr[31:12] == 20'h00001);
    wire w_sel_accel  = (reg_d_addr[31:8]  == 24'h100000);
    wire w_sel_dmacfg = (reg_d_addr[31:8]  == 24'h100001);
    wire w_sel_timer  = (reg_d_addr[31:8]  == 24'h200000);
    wire w_sel_uart   = (reg_d_addr[31:8]  == 24'h200001);
    wire w_sel_gpio   = (reg_d_addr[31:8]  == 24'h200002);
    wire w_sel_crc    = (reg_d_addr[31:8]  == 24'h200003);
    wire w_sel_spi    = (reg_d_addr[31:8]  == 24'h200004);
    wire w_sel_sys    = (reg_d_addr[31:8]  == 24'h200005);
    wire w_sel_none   = !(w_sel_isram || w_sel_dsram || w_sel_accel ||
                          w_sel_dmacfg || w_sel_timer || w_sel_uart ||
                          w_sel_gpio || w_sel_crc || w_sel_spi || w_sel_sys);

    // Boot-region protection: 0x0000_0000 .. 0x0000_01FF (first 512 bytes)
    wire w_boot_prot_hit = i_boot_lock && reg_d_we && w_sel_isram &&
                           (reg_d_addr[11:9] == 3'b000);

    // Prevent DMA from writing/reading its own MMIO registers
    wire w_dma_self_hit  = w_sel_dmacfg && (reg_d_master == LP_M_DMA);

    // -------------------------------------------------------------------------
    // Channel 1: I-SRAM Round-Robin arbitration (CPU0 / CPU1 / D-Bus)
    // -------------------------------------------------------------------------
    wire w_dbus_wants_isram = (reg_d_state == LP_D_WAIT) && w_sel_isram &&
                              !w_boot_prot_hit;
    wire w_isram_dbus_done  = (reg_isram_state == LP_IS_DBUS) && i_isram_ready;

    wire w_pick_imem0 = !w_dbus_wants_isram &&
                        (reg_imem_rr ? (i_imem0_req && !i_imem1_req) : i_imem0_req);
    wire w_pick_imem1 = !w_dbus_wants_isram &&
                        (reg_imem_rr ? i_imem1_req : (i_imem1_req && !i_imem0_req));

    always @(*) begin : p_isram_mux
        o_isram_req   = 1'b0;
        o_isram_we    = 1'b0;
        o_isram_be    = 4'b1111;
        o_isram_addr  = 12'd0;
        o_isram_wdata = 32'd0;

        if (reg_isram_state == LP_IS_IDLE) begin
            if (w_dbus_wants_isram) begin
                o_isram_req   = 1'b1;
                o_isram_we    = reg_d_we;
                o_isram_be    = reg_d_be;
                o_isram_addr  = reg_d_addr[11:0];
                o_isram_wdata = reg_d_wdata;
            end else if (w_pick_imem0) begin
                o_isram_req   = 1'b1;
                o_isram_we    = 1'b0;
                o_isram_be    = 4'b1111;
                o_isram_addr  = i_imem0_addr[11:0];
                o_isram_wdata = 32'd0;
            end else if (w_pick_imem1) begin
                o_isram_req   = 1'b1;
                o_isram_we    = 1'b0;
                o_isram_be    = 4'b1111;
                o_isram_addr  = i_imem1_addr[11:0];
                o_isram_wdata = 32'd0;
            end
        end
    end

    wire w_isram_master_rst = ((reg_isram_state == LP_IS_IMEM0) && i_cpu0_soft_rst) ||
                              ((reg_isram_state == LP_IS_IMEM1) && i_cpu1_soft_rst);

    assign o_imem0_ready = (reg_isram_state == LP_IS_IMEM0) && i_isram_ready &&
                           !reg_isram_drop && !i_cpu0_soft_rst;
    assign o_imem0_rdata = o_imem0_ready ? i_isram_rdata : 32'd0;

    assign o_imem1_ready = (reg_isram_state == LP_IS_IMEM1) && i_isram_ready &&
                           !reg_isram_drop && !i_cpu1_soft_rst;
    assign o_imem1_rdata = o_imem1_ready ? i_isram_rdata : 32'd0;

    always @(posedge i_clk or negedge i_resetn) begin : p_isram_arb
        if (!i_resetn) begin
            reg_isram_state <= LP_IS_IDLE;
            reg_imem_rr     <= 1'b0;
            reg_isram_drop  <= 1'b0;
        end else begin
            case (reg_isram_state)
                LP_IS_IDLE: begin
                    reg_isram_drop <= 1'b0;
                    if (w_dbus_wants_isram) begin
                        reg_isram_state <= LP_IS_DBUS;
                    end else if (w_pick_imem0) begin
                        reg_isram_state <= LP_IS_IMEM0;
                        reg_imem_rr     <= 1'b1;
                    end else if (w_pick_imem1) begin
                        reg_isram_state <= LP_IS_IMEM1;
                        reg_imem_rr     <= 1'b0;
                    end
                end
                LP_IS_IMEM0,
                LP_IS_IMEM1: begin
                    if (i_isram_ready) begin
                        reg_isram_state <= LP_IS_IDLE;
                        reg_isram_drop  <= 1'b0;
                    end else if (w_isram_master_rst) begin
                        reg_isram_drop  <= 1'b1;
                    end
                end
                LP_IS_DBUS: begin
                    if (i_isram_ready) begin
                        reg_isram_state <= LP_IS_IDLE;
                    end
                end
                default: begin
                    reg_isram_state <= LP_IS_IDLE;
                    reg_isram_drop  <= 1'b0;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Channel 2: 3-Master Round-Robin Arbiter (CPU0, CPU1, DMA)
    // -------------------------------------------------------------------------
    reg        w_grant_valid;
    reg [1:0]  w_grant_id;
    reg [31:0] w_grant_addr;
    reg        w_grant_we;
    reg [3:0]  w_grant_be;
    reg [31:0] w_grant_wdata;
    reg [1:0]  w_next_rr_ptr;

    always @(*) begin : p_d_arb
        w_grant_valid = 1'b0;
        w_grant_id    = LP_M_CPU0;
        case (reg_d_rr_ptr)
            LP_M_CPU0: begin
                if (i_dmem0_req) begin
                    w_grant_valid = 1'b1;
                    w_grant_id    = LP_M_CPU0;
                end else if (i_dmem1_req) begin
                    w_grant_valid = 1'b1;
                    w_grant_id    = LP_M_CPU1;
                end else if (i_dma_req) begin
                    w_grant_valid = 1'b1;
                    w_grant_id    = LP_M_DMA;
                end
            end
            LP_M_CPU1: begin
                if (i_dmem1_req) begin
                    w_grant_valid = 1'b1;
                    w_grant_id    = LP_M_CPU1;
                end else if (i_dma_req) begin
                    w_grant_valid = 1'b1;
                    w_grant_id    = LP_M_DMA;
                end else if (i_dmem0_req) begin
                    w_grant_valid = 1'b1;
                    w_grant_id    = LP_M_CPU0;
                end
            end
            default: begin
                if (i_dma_req) begin
                    w_grant_valid = 1'b1;
                    w_grant_id    = LP_M_DMA;
                end else if (i_dmem0_req) begin
                    w_grant_valid = 1'b1;
                    w_grant_id    = LP_M_CPU0;
                end else if (i_dmem1_req) begin
                    w_grant_valid = 1'b1;
                    w_grant_id    = LP_M_CPU1;
                end
            end
        endcase

        case (w_grant_id)
            LP_M_CPU0: begin
                w_grant_addr  = i_dmem0_addr;
                w_grant_we    = i_dmem0_we;
                w_grant_be    = i_dmem0_be;
                w_grant_wdata = i_dmem0_wdata;
                w_next_rr_ptr = LP_M_CPU1;
            end
            LP_M_CPU1: begin
                w_grant_addr  = i_dmem1_addr;
                w_grant_we    = i_dmem1_we;
                w_grant_be    = i_dmem1_be;
                w_grant_wdata = i_dmem1_wdata;
                w_next_rr_ptr = LP_M_DMA;
            end
            default: begin
                w_grant_addr  = i_dma_addr;
                w_grant_we    = i_dma_we;
                w_grant_be    = i_dma_be;
                w_grant_wdata = i_dma_wdata;
                w_next_rr_ptr = LP_M_CPU0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Data / MMIO slave request & response mux
    // -------------------------------------------------------------------------
    assign o_dsram_req   = (reg_d_state == LP_D_WAIT) && w_sel_dsram;
    assign o_dsram_we    = reg_d_we;
    assign o_dsram_be    = reg_d_be;
    assign o_dsram_addr  = reg_d_addr[11:0];
    assign o_dsram_wdata = reg_d_wdata;

    assign o_accel_req   = (reg_d_state == LP_D_WAIT) && w_sel_accel;
    assign o_accel_we    = reg_d_we;
    assign o_accel_addr  = reg_d_addr[7:0];
    assign o_accel_wdata = reg_d_wdata;

    assign o_dmacfg_req   = (reg_d_state == LP_D_WAIT) && w_sel_dmacfg && !w_dma_self_hit;
    assign o_dmacfg_we    = reg_d_we;
    assign o_dmacfg_addr  = reg_d_addr[7:0];
    assign o_dmacfg_wdata = reg_d_wdata;

    assign o_timer_req   = (reg_d_state == LP_D_WAIT) && w_sel_timer;
    assign o_timer_we    = reg_d_we;
    assign o_timer_addr  = reg_d_addr[4:0];
    assign o_timer_wdata = reg_d_wdata;

    assign o_uart_req    = (reg_d_state == LP_D_WAIT) && w_sel_uart;
    assign o_uart_we     = reg_d_we;
    assign o_uart_addr   = reg_d_addr[4:0];
    assign o_uart_wdata  = reg_d_wdata;

    assign o_gpio_req    = (reg_d_state == LP_D_WAIT) && w_sel_gpio;
    assign o_gpio_we     = reg_d_we;
    assign o_gpio_addr   = reg_d_addr[4:0];
    assign o_gpio_wdata  = reg_d_wdata;

    assign o_crc_req     = (reg_d_state == LP_D_WAIT) && w_sel_crc;
    assign o_crc_we      = reg_d_we;
    assign o_crc_addr    = reg_d_addr[4:0];
    assign o_crc_wdata   = reg_d_wdata;

    assign o_spi_req     = (reg_d_state == LP_D_WAIT) && w_sel_spi;
    assign o_spi_we      = reg_d_we;
    assign o_spi_addr    = reg_d_addr[4:0];
    assign o_spi_wdata   = reg_d_wdata;

    assign o_sys_req       = (reg_d_state == LP_D_WAIT) && w_sel_sys;
    assign o_sys_we        = reg_d_we;
    assign o_sys_addr      = reg_d_addr[5:0];
    assign o_sys_wdata     = reg_d_wdata;
    assign o_sys_master_id = reg_d_master;

    wire w_dslave_ready = (w_sel_isram && (w_boot_prot_hit || w_isram_dbus_done)) ||
                          (w_sel_dsram && i_dsram_ready)  ||
                          (w_sel_accel && i_accel_ready)  ||
                          (w_sel_dmacfg && (w_dma_self_hit || i_dmacfg_ready)) ||
                          (w_sel_timer && i_timer_ready)  ||
                          (w_sel_uart  && i_uart_ready)   ||
                          (w_sel_gpio  && i_gpio_ready)   ||
                          (w_sel_crc   && i_crc_ready)    ||
                          (w_sel_spi   && i_spi_ready)    ||
                          (w_sel_sys   && i_sys_ready)    ||
                          w_sel_none;

    wire [31:0] w_dslave_rdata =
        (w_sel_isram && !w_boot_prot_hit)   ? i_isram_rdata  :
        w_sel_dsram                         ? i_dsram_rdata  :
        w_sel_accel                         ? i_accel_rdata  :
        (w_sel_dmacfg && !w_dma_self_hit)   ? i_dmacfg_rdata :
        w_sel_timer                         ? i_timer_rdata  :
        w_sel_uart                          ? i_uart_rdata   :
        w_sel_gpio                          ? i_gpio_rdata   :
        w_sel_crc                           ? i_crc_rdata    :
        w_sel_spi                           ? i_spi_rdata    :
        w_sel_sys                           ? i_sys_rdata    : 32'd0;

    wire w_d_master_rst = ((reg_d_master == LP_M_CPU0) && i_cpu0_soft_rst) ||
                          ((reg_d_master == LP_M_CPU1) && i_cpu1_soft_rst) ||
                          ((reg_d_master == LP_M_DMA)  && i_dma_soft_rst);

    always @(*) begin : p_dbus_rsp
        o_dmem0_ready = 1'b0;
        o_dmem0_rdata = 32'd0;
        o_dmem1_ready = 1'b0;
        o_dmem1_rdata = 32'd0;
        o_dma_ready   = 1'b0;
        o_dma_rdata   = 32'd0;
        if (reg_d_state == LP_D_RESP) begin
            case (reg_d_master)
                LP_M_CPU0: begin
                    o_dmem0_ready = !i_cpu0_soft_rst;
                    o_dmem0_rdata = reg_d_rdata;
                end
                LP_M_CPU1: begin
                    o_dmem1_ready = !i_cpu1_soft_rst;
                    o_dmem1_rdata = reg_d_rdata;
                end
                default: begin
                    o_dma_ready   = !i_dma_soft_rst;
                    o_dma_rdata   = reg_d_rdata;
                end
            endcase
        end
    end

    always @(posedge i_clk or negedge i_resetn) begin : p_dbus_fsm
        if (!i_resetn) begin
            reg_d_state      <= LP_D_IDLE;
            reg_d_master     <= LP_M_CPU0;
            reg_d_rr_ptr     <= LP_M_CPU0;
            reg_d_drop       <= 1'b0;
            reg_d_addr       <= 32'd0;
            reg_d_we         <= 1'b0;
            reg_d_be         <= 4'd0;
            reg_d_wdata      <= 32'd0;
            reg_d_rdata      <= 32'd0;
            o_boot_lock_viol <= 1'b0;
        end else begin
            o_boot_lock_viol <= 1'b0;

            case (reg_d_state)
                LP_D_IDLE: begin
                    reg_d_drop <= 1'b0;
                    if (w_grant_valid) begin
                        reg_d_master <= w_grant_id;
                        reg_d_rr_ptr <= w_next_rr_ptr;
                        reg_d_addr   <= w_grant_addr;
                        reg_d_we     <= w_grant_we;
                        reg_d_be     <= w_grant_be;
                        reg_d_wdata  <= w_grant_wdata;
                        reg_d_state  <= LP_D_WAIT;
                    end
                end

                LP_D_WAIT: begin
                    if (w_boot_prot_hit) begin
                        o_boot_lock_viol <= 1'b1;
                    end
                    if (w_dslave_ready) begin
                        reg_d_rdata <= w_dslave_rdata;
                        reg_d_drop  <= 1'b0;
                        if (reg_d_drop || w_d_master_rst) begin
                            reg_d_state <= LP_D_IDLE;
                        end else begin
                            reg_d_state <= LP_D_RESP;
                        end
                    end else if (w_d_master_rst) begin
                        reg_d_drop <= 1'b1;
                    end
                end

                LP_D_RESP: begin
                    reg_d_state <= LP_D_IDLE;
                end

                default: begin
                    reg_d_state <= LP_D_IDLE;
                    reg_d_drop  <= 1'b0;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
