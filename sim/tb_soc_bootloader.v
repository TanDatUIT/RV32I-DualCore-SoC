// =============================================================================
// Testbench   : tb_soc_bootloader
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : Verification of Secure UART Bootloader + HW CRC32 + Boot-Lock.
//               Phase A (Negative Security Test): inject corrupted CRC32 ->
//                 Bootloader must reject with NAK (0x15) and NOT execute app.
//               Phase B (Positive Secure Boot): send valid CRC32 ->
//                 Bootloader must reply EOT (0x04), engage BOOT_LOCK, jump to
//                 0x0000_0200, set GPIO_OUT = 0xCAFE, and transmit "OK!".
// =============================================================================
`timescale 1ns / 1ps

module tb_soc_bootloader;

    localparam integer PR_CLKS_PER_BIT = 16;
    localparam real    CLK_PERIOD      = 10.0; // 100 MHz
    localparam real    BIT_PERIOD      = CLK_PERIOD * PR_CLKS_PER_BIT;

    reg         clk;
    reg         resetn;

    reg         uart_rxd;
    wire        uart_txd;

    reg  [15:0] gpio_in;
    wire [15:0] gpio_out;
    wire [15:0] gpio_oe;

    wire        spi_sclk;
    wire        spi_mosi;
    wire        spi_cs_n;
    wire        wdt_rst;

    reg [31:0]  fw_app_mem [0:255];
    integer     fw_app_len;
    reg [31:0]  expected_crc;
    reg [31:0]  bad_crc;

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
        .i_spi_miso (spi_mosi),
        .o_spi_cs_n (spi_cs_n),
        .o_wdt_rst  (wdt_rst)
    );

    function [31:0] crc32_update_byte;
        input [31:0] c_in;
        input [7:0]  b_in;
        reg   [31:0] v;
        integer      i;
        begin
            v = c_in ^ {24'd0, b_in};
            for (i = 0; i < 8; i = i + 1) begin
                if (v[0]) v = (v >> 1) ^ 32'hEDB8_8320;
                else      v = (v >> 1);
            end
            crc32_update_byte = v;
        end
    endfunction

    task send_host_byte;
        input [7:0] data;
        integer b;
        begin
            uart_rxd = 1'b0;
            #(BIT_PERIOD);
            for (b = 0; b < 8; b = b + 1) begin
                uart_rxd = data[b];
                #(BIT_PERIOD);
            end
            uart_rxd = 1'b1;
            #(BIT_PERIOD);
        end
    endtask

    task recv_soc_byte;
        output [7:0] data;
        integer b;
        begin
            @(negedge uart_txd);
            #(BIT_PERIOD / 2.0);
            #(BIT_PERIOD);
            for (b = 0; b < 8; b = b + 1) begin
                data[b] = uart_txd;
                #(BIT_PERIOD);
            end
            #(BIT_PERIOD / 2.0);
        end
    endtask

    task load_app_hex;
        integer fd;
        integer rc;
        reg [31:0] w;
        reg [31:0] crc_acc;
        begin
            fw_app_len = 0;
            crc_acc    = 32'hFFFF_FFFF;
            fd = $fopen("firmware/apps/app_update.hex", "r");
            if (fd == 0) begin
                $fatal(1, "Cannot open firmware/apps/app_update.hex");
            end
            while (!$feof(fd)) begin
                rc = $fscanf(fd, "%h\n", w);
                if (rc == 1) begin
                    fw_app_mem[fw_app_len] = w;
                    crc_acc = crc32_update_byte(crc_acc, w[7:0]);
                    crc_acc = crc32_update_byte(crc_acc, w[15:8]);
                    crc_acc = crc32_update_byte(crc_acc, w[23:16]);
                    crc_acc = crc32_update_byte(crc_acc, w[31:24]);
                    fw_app_len = fw_app_len + 1;
                end
            end
            $fclose(fd);
            expected_crc = crc_acc ^ 32'hFFFF_FFFF;
            bad_crc      = expected_crc ^ 32'h0000_0001;
        end
    endtask

    task stream_firmware_and_crc;
        input [31:0] crc_to_send;
        integer w_idx;
        reg [7:0]  rx_resp;
        reg [31:0] cur_word;
        begin
            send_host_byte(8'h7F);
            recv_soc_byte(rx_resp);
            if (rx_resp !== 8'h79) begin
                $display("[-] Expected 'y' (0x79), got 0x%02x", rx_resp);
                $fatal(1, "Bootloader sync failed");
            end
            send_host_byte(fw_app_len[7:0]);
            for (w_idx = 0; w_idx < fw_app_len; w_idx = w_idx + 1) begin
                cur_word = fw_app_mem[w_idx];
                send_host_byte(cur_word[7:0]);
                send_host_byte(cur_word[15:8]);
                send_host_byte(cur_word[23:16]);
                send_host_byte(cur_word[31:24]);
                recv_soc_byte(rx_resp);
                if (rx_resp !== 8'h06) begin
                    $display("[-] Expected ACK 0x06 at word %0d, got 0x%02x", w_idx, rx_resp);
                    $fatal(1, "Word ACK failed");
                end
            end
            // Send 4-byte CRC32 little-endian
            send_host_byte(crc_to_send[7:0]);
            send_host_byte(crc_to_send[15:8]);
            send_host_byte(crc_to_send[23:16]);
            send_host_byte(crc_to_send[31:24]);
        end
    endtask

    reg [7:0] resp;
    reg [7:0] ch0, ch1, ch2;

    initial begin
        $display("==================================================================");
        $display("  SECURE UART BOOTLOADER + HW CRC32 + BOOT-LOCK VERIFICATION      ");
        $display("==================================================================");

        uart_rxd = 1'b1;
        gpio_in  = 16'h0000;
        resetn   = 1'b0;

        load_app_hex();
        $display("[TB_BOOT] Loaded app_update.hex (%0d words, CRC32 = 0x%08x)",
                 fw_app_len, expected_crc);

`ifdef GATE_SIM
        $readmemh("firmware/bootloader/bootloader.hex",
                  u_soc_top.u_isram_ctrl_u_sram_macro.mem);
`else
        $readmemh("firmware/bootloader/bootloader.hex",
                  u_soc_top.u_isram_ctrl.u_sram_macro.mem);
`endif

        #(CLK_PERIOD * 10);
        resetn = 1'b1;
        #(CLK_PERIOD * 50);

        // Phase A: Negative Security Test (corrupted CRC32 must be rejected)
        $display("[TB_BOOT] [Phase A] Streaming firmware with CORRUPTED CRC32 = 0x%08x...", bad_crc);
        stream_firmware_and_crc(bad_crc);
        recv_soc_byte(resp);
        if (resp !== 8'h15) begin
            $display("[-] Phase A FAILED: expected NAK (0x15), got 0x%02x", resp);
            $fatal(1, "Corrupted firmware was not rejected");
        end
        if (gpio_out !== 16'h0000) begin
            $display("[-] Phase A FAILED: gpio_out changed to 0x%04x!", gpio_out);
            $fatal(1, "Rejected firmware executed");
        end
        $display("[TB_BOOT] [Phase A] PASS: Corrupted firmware rejected with NAK (0x15)!");

        // Phase B: Positive Secure Boot (valid CRC32)
        #(BIT_PERIOD * 2);
        $display("[TB_BOOT] [Phase B] Streaming firmware with VALID CRC32 = 0x%08x...", expected_crc);
        stream_firmware_and_crc(expected_crc);
        recv_soc_byte(resp);
        if (resp !== 8'h04) begin
            $display("[-] Phase B FAILED: expected EOT (0x04), got 0x%02x", resp);
            $fatal(1, "Valid firmware did not return EOT");
        end

        // Receive "OK!" from updated application
        recv_soc_byte(ch0);
        recv_soc_byte(ch1);
        recv_soc_byte(ch2);
        #(CLK_PERIOD * 20);

        if ((gpio_oe !== 16'hFFFF) || (gpio_out !== 16'hCAFE) ||
            (ch0 !== "O") || (ch1 !== "K") || (ch2 !== "!")) begin
            $display("[-] Phase B FAILED: gpio_oe=0x%04x gpio_out=0x%04x uart=%c%c%c",
                     gpio_oe, gpio_out, ch0, ch1, ch2);
            $fatal(1, "Updated app execution check failed");
        end

`ifndef GATE_SIM
        if (u_soc_top.u_sysctrl.o_boot_lock !== 1'b1) begin
            $display("[-] Phase B FAILED: BOOT_LOCK not engaged!");
            $fatal(1, "Boot lock check failed");
        end
`endif

        $display("==================================================================");
        $display("  [TB_BOOT] SECURE BOOTLOADER PASS 100%%! GPIO=0x%04x UART=\"%c%c%c\"",
                 gpio_out, ch0, ch1, ch2);
        $display("==================================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 2000000);
        $display("[-] TIMEOUT in tb_soc_bootloader!");
        $fatal(1, "tb_soc_bootloader timed out");
    end

endmodule
