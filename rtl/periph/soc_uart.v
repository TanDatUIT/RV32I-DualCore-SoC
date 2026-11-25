// =============================================================================
// Module      : soc_uart
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : 8N1 UART, MMIO mapped.
//               0x00 TXDATA (W)  byte to transmit
//               0x04 RXDATA (R)  last received byte (read clears rx_valid)
//               0x08 STATUS (R)  [0] tx_busy, [1] rx_valid
//               0x0C CTRL   (RW) [0] enable
//
//               PR_CLKS_PER_BIT = 868 -> 115200 baud at 100 MHz
//                               = 434 -> 115200 baud at 50 MHz
//                               =  87 -> 115200 baud at 10 MHz
// =============================================================================
`default_nettype none

module soc_uart #(
    parameter integer PR_CLKS_PER_BIT = 868
)(
    input  wire        i_clk,
    input  wire        i_resetn,

    input  wire        i_req,
    input  wire        i_we,
    input  wire [4:0]  i_addr,
    input  wire [31:0] i_wdata,

    output reg  [31:0] o_rdata,
    output wire        o_ready,

    input  wire        i_uart_rxd,
    output reg         o_uart_txd
);

    localparam [1:0] LP_REG_TXDATA = 2'd0;
    localparam [1:0] LP_REG_RXDATA = 2'd1;
    localparam [1:0] LP_REG_STATUS = 2'd2;
    localparam [1:0] LP_REG_CTRL   = 2'd3;

    localparam [1:0] LP_TX_IDLE = 2'd0;
    localparam [1:0] LP_TX_DATA = 2'd1;
    localparam [1:0] LP_TX_STOP = 2'd2;

    localparam [2:0] LP_RX_IDLE  = 3'd0;
    localparam [2:0] LP_RX_START = 3'd1;
    localparam [2:0] LP_RX_DATA  = 3'd2;
    localparam [2:0] LP_RX_STOP  = 3'd3;

    wire [1:0] w_reg_sel = i_addr[3:2];

    reg        reg_en;

    // ---------------- transmitter ----------------
    reg [1:0]  reg_tx_state;
    reg [9:0]  reg_tx_shift;      // {stop, d[7:0], start}
    reg [3:0]  reg_tx_bit;
    reg [15:0] reg_tx_cnt;
    reg        reg_tx_busy;

    // ---------------- receiver -------------------
    reg [2:0]  reg_rx_state;
    reg [2:0]  reg_rx_bit;
    reg [15:0] reg_rx_cnt;
    reg [7:0]  reg_rx_shift;
    reg [7:0]  reg_rx_data;
    reg        reg_rx_valid;
    reg [2:0]  reg_rxd_sync;      // 3-stage synchroniser

    assign o_ready = i_req;

    // -------------------------------------------------------------------------
    // Read mux
    // -------------------------------------------------------------------------
    always @(*) begin : p_read
        o_rdata = 32'd0;
        if (!i_we) begin
            case (w_reg_sel)
                LP_REG_RXDATA: o_rdata = {24'd0, reg_rx_data};
                LP_REG_STATUS: o_rdata = {30'd0, reg_rx_valid, reg_tx_busy};
                LP_REG_CTRL  : o_rdata = {31'd0, reg_en};
                default      : o_rdata = 32'd0;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Control / status writes
    // -------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_resetn) begin : p_ctrl
        if (!i_resetn) begin
            reg_en <= 1'b0;
        end else if (i_req && i_we && (w_reg_sel == LP_REG_CTRL)) begin
            reg_en <= i_wdata[0];
        end
    end

    // -------------------------------------------------------------------------
    // Transmitter
    // -------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_resetn) begin : p_tx
        if (!i_resetn) begin
            reg_tx_state <= LP_TX_IDLE;
            reg_tx_shift <= 10'h3FF;
            reg_tx_bit   <= 4'd0;
            reg_tx_cnt   <= 16'd0;
            reg_tx_busy  <= 1'b0;
            o_uart_txd   <= 1'b1;
        end else if (!reg_en) begin
            reg_tx_state <= LP_TX_IDLE;
            reg_tx_busy  <= 1'b0;
            o_uart_txd   <= 1'b1;
        end else begin
            case (reg_tx_state)
                LP_TX_IDLE: begin
                    o_uart_txd <= 1'b1;
                    if (i_req && i_we && (w_reg_sel == LP_REG_TXDATA)) begin
                        reg_tx_shift <= {1'b1, i_wdata[7:0], 1'b0};
                        reg_tx_bit   <= 4'd1;
                        reg_tx_cnt   <= 16'd0;
                        reg_tx_busy  <= 1'b1;
                        o_uart_txd   <= 1'b0;          // start bit
                        reg_tx_state <= LP_TX_DATA;
                    end
                end

                LP_TX_DATA: begin
                    if ({16'd0, reg_tx_cnt} == (PR_CLKS_PER_BIT - 1)) begin
                        reg_tx_cnt <= 16'd0;
                        o_uart_txd <= reg_tx_shift[reg_tx_bit];
                        if (reg_tx_bit == 4'd9) begin
                            reg_tx_state <= LP_TX_STOP;
                        end else begin
                            reg_tx_bit <= reg_tx_bit + 4'd1;
                        end
                    end else begin
                        reg_tx_cnt <= reg_tx_cnt + 16'd1;
                    end
                end

                LP_TX_STOP: begin
                    if ({16'd0, reg_tx_cnt} == (PR_CLKS_PER_BIT - 1)) begin
                        reg_tx_cnt   <= 16'd0;
                        o_uart_txd   <= 1'b1;
                        reg_tx_busy  <= 1'b0;
                        reg_tx_state <= LP_TX_IDLE;
                    end else begin
                        reg_tx_cnt <= reg_tx_cnt + 16'd1;
                    end
                end

                default: reg_tx_state <= LP_TX_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Receiver
    // -------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_resetn) begin : p_rx
        if (!i_resetn) begin
            reg_rx_state <= LP_RX_IDLE;
            reg_rx_bit   <= 3'd0;
            reg_rx_cnt   <= 16'd0;
            reg_rx_shift <= 8'd0;
            reg_rx_data  <= 8'd0;
            reg_rx_valid <= 1'b0;
            reg_rxd_sync <= 3'b111;
        end else begin
            reg_rxd_sync <= {reg_rxd_sync[1:0], i_uart_rxd};

            if (i_req && !i_we && (w_reg_sel == LP_REG_RXDATA)) begin
                reg_rx_valid <= 1'b0;
            end

            if (!reg_en) begin
                reg_rx_state <= LP_RX_IDLE;
            end else begin
                case (reg_rx_state)
                    LP_RX_IDLE: begin
                        reg_rx_cnt <= 16'd0;
                        if (!reg_rxd_sync[2]) begin
                            reg_rx_state <= LP_RX_START;
                        end
                    end

                    LP_RX_START: begin
                        if ({16'd0, reg_rx_cnt} == ((PR_CLKS_PER_BIT / 2) - 1)) begin
                            reg_rx_cnt <= 16'd0;
                            if (!reg_rxd_sync[2]) begin
                                reg_rx_bit   <= 3'd0;
                                reg_rx_state <= LP_RX_DATA;
                            end else begin
                                reg_rx_state <= LP_RX_IDLE;   // glitch
                            end
                        end else begin
                            reg_rx_cnt <= reg_rx_cnt + 16'd1;
                        end
                    end

                    LP_RX_DATA: begin
                        if ({16'd0, reg_rx_cnt} == (PR_CLKS_PER_BIT - 1)) begin
                            reg_rx_cnt   <= 16'd0;
                            reg_rx_shift <= {reg_rxd_sync[2], reg_rx_shift[7:1]};
                            if (reg_rx_bit == 3'd7) begin
                                reg_rx_state <= LP_RX_STOP;
                            end else begin
                                reg_rx_bit <= reg_rx_bit + 3'd1;
                            end
                        end else begin
                            reg_rx_cnt <= reg_rx_cnt + 16'd1;
                        end
                    end

                    LP_RX_STOP: begin
                        if ({16'd0, reg_rx_cnt} == (PR_CLKS_PER_BIT - 1)) begin
                            reg_rx_cnt   <= 16'd0;
                            reg_rx_data  <= reg_rx_shift;
                            reg_rx_valid <= 1'b1;
                            reg_rx_state <= LP_RX_IDLE;
                        end else begin
                            reg_rx_cnt <= reg_rx_cnt + 16'd1;
                        end
                    end

                    default: reg_rx_state <= LP_RX_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
