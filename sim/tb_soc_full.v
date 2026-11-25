// =============================================================================
// Testbench   : tb_soc_full
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : Self-checking system-level testbench for soc_top executing
//               firmware/tests/soc_full_test.hex:
//                 1. RV32I ISA, forwarding, load-use, JAL-after-SW, D-SRAM RMW
//                 2. DMA SRAM->SRAM & DMA->Mini-NPU 4x4 Skewed Systolic + PostProc
//                 3. Timer + SPI Master (all 4 CPOL/CPHA modes loopback) + UART
//                 4. HW CRC32 ("123456789" == 0xCBF43926)
//                 5. Boot-Region Write-Lock security check
//                 6. Hardware Perf Counters (MCYCLE / MINSTRET -> CPI/IPC)
//                 7. Watchdog Reset pulse (o_wdt_rst) + Post-WDT reboot check
// =============================================================================
`timescale 1ns / 1ps

module tb_soc_full;

    localparam integer PR_CLKS_PER_BIT = 16;
    localparam real    CLK_PERIOD      = 10.0; // 100 MHz

    reg         clk;
    reg         resetn;

    reg         uart_rxd;
    wire        uart_txd;

    reg  [15:0] gpio_in;
    wire [15:0] gpio_out;
    wire [15:0] gpio_oe;

    wire        spi_sclk;
    wire        spi_mosi;
    wire        spi_miso;
    wire        spi_cs_n;
    wire        wdt_rst;

    // External SPI loopback for self-test across all 4 modes
    assign spi_miso = spi_mosi;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    soc_top #(
        .PR_UART_CLKS_PER_BIT (PR_CLKS_PER_BIT)
    ) u_soc_top (
        .i_clk      (clk),
        .i_resetn   (resetn),
        .i_uart_rxd (uart_rxd),
        .o_uart_txd (uart_txd),
        .i_gpio_in  (gpio_in),
        .o_gpio_out (gpio_out),
        .o_gpio_oe  (gpio_oe),
        .o_spi_sclk (spi_sclk),
        .o_spi_mosi (spi_mosi),
        .i_spi_miso (spi_miso),
        .o_spi_cs_n (spi_cs_n),
        .o_wdt_rst  (wdt_rst)
    );

    reg        seen_stage1_pass;
    reg        seen_wdt_rst;
    reg        seen_stage2_pass;
    integer    cyc_cnt;
    reg [31:0] mcycle_val;
    reg [31:0] minstret0_val;
    reg [31:0] minstret1_val;
    reg [31:0] minstret_tot;

    initial begin
        if ($test$plusargs("DUMP_VCD")) begin
            $dumpfile("work_sim/soc_full.vcd");
            $dumpvars(0, tb_soc_full.u_soc_top);
        end

        uart_rxd         = 1'b1;
        gpio_in          = 16'h1234;
        resetn           = 1'b0;
        seen_stage1_pass = 1'b0;
        seen_wdt_rst     = 1'b0;
        seen_stage2_pass = 1'b0;
        cyc_cnt          = 0;

`ifdef GATE_SIM
        $readmemh("firmware/tests/soc_full_test.hex",
                  u_soc_top.u_isram_ctrl_u_sram_macro.mem);
`else
        $readmemh("firmware/tests/soc_full_test.hex",
                  u_soc_top.u_isram_ctrl.u_sram_macro.mem);
`endif

        #(CLK_PERIOD * 10);
        resetn = 1'b1;
        $display("[TB_FULL] Released reset at %0t ns", $time);

        while (!seen_stage2_pass && (cyc_cnt < 50000)) begin
            @(posedge clk);
            cyc_cnt = cyc_cnt + 1;

            if ((gpio_oe === 16'hFFFF) && ((gpio_out & 16'hFF00) === 16'hDE00)) begin
                $display("[TB_FULL] FAIL signature detected: GPIO_OUT = 0x%04x at cycle %0d",
                         gpio_out, cyc_cnt);
                $display("[FATAL] SoC self-test failed");
                $finish;
            end

            if (!seen_stage1_pass && (gpio_oe === 16'hFFFF) && (gpio_out === 16'hA55A)) begin
                seen_stage1_pass = 1'b1;
                $display("[TB_FULL] Stage 1 PASS (ISA + Dual-SRAM + DMA + Mini-NPU + Timer + SPI + CRC32 + Boot-Lock) at cycle %0d",
                         cyc_cnt);
            end

            if (wdt_rst === 1'b1) begin
                seen_wdt_rst = 1'b1;
                $display("[TB_FULL] Watchdog reset pulse observed at cycle %0d", cyc_cnt);
            end

            if (seen_stage1_pass && seen_wdt_rst &&
                (gpio_oe === 16'hFFFF) && (gpio_out === 16'hBEEF)) begin
                seen_stage2_pass = 1'b1;
                $display("[TB_FULL] Stage 2 PASS (Post-Watchdog reboot & SOC_ID verified) at cycle %0d",
                         cyc_cnt);
            end
        end

        if (!seen_stage2_pass) begin
            $display("[TB_FULL] TIMEOUT! stage1=%b wdt=%b stage2=%b gpio_out=0x%04x",
                     seen_stage1_pass, seen_wdt_rst, seen_stage2_pass, gpio_out);
            $display("[FATAL] tb_soc_full timed out");
            $finish;
        end

`ifdef GATE_SIM
        mcycle_val    = u_soc_top.u_dsram_ctrl_u_sram_macro.mem[10'h0C0];
        minstret0_val = u_soc_top.u_dsram_ctrl_u_sram_macro.mem[10'h0C1];
        minstret1_val = u_soc_top.u_dsram_ctrl_u_sram_macro.mem[10'h0C2];
`else
        mcycle_val    = u_soc_top.u_dsram_ctrl.u_sram_macro.mem[10'h0C0];
        minstret0_val = u_soc_top.u_dsram_ctrl.u_sram_macro.mem[10'h0C1];
        minstret1_val = u_soc_top.u_dsram_ctrl.u_sram_macro.mem[10'h0C2];
`endif
        minstret_tot = minstret0_val + minstret1_val;
        $display("==================================================================");
        $display("  [TB_FULL] ALL DUAL-CORE SOC TESTS PASSED 100%%!");
        $display("  Perf Counters -> MCYCLE = %0d | MINSTRET0 = %0d | MINSTRET1 = %0d | TOTAL = %0d | Dual-Core CPI x100 = %0d",
                 mcycle_val, minstret0_val, minstret1_val, minstret_tot,
                 (minstret_tot != 0) ? ((mcycle_val * 100) / minstret_tot) : 0);
        $display("==================================================================");
        #(CLK_PERIOD * 20);
        $finish;
    end

endmodule
