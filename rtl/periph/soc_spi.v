// =============================================================================
// Module      : soc_spi
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : 8-bit full-duplex SPI Master supporting all 4 (CPOL, CPHA)
//               modes, programmable clock divider, auto or manual CS_n.
//
// Register map (Base 0x2000_0400, byte offsets):
//   0x00 TXDATA [7:0] start 8-bit transfer when en=1 && !busy (W)
//   0x04 RXDATA [7:0] last received byte, read clears rx_valid (R)
//   0x08 STATUS [0] busy, [1] rx_valid (R)
//   0x0C CTRL   [0] en, [1] cpol, [2] cpha, [3] cs_auto (rst=1),
//               [4] cs_manual (rst=1), [15:8] clkdiv (half-period - 1, rst=3)
// =============================================================================
`default_nettype none

module soc_spi (
    input  wire        i_clk,
    input  wire        i_resetn,

    input  wire        i_req,
    input  wire        i_we,
    input  wire [4:0]  i_addr,
    input  wire [31:0] i_wdata,

    output reg  [31:0] o_rdata,
    output wire        o_ready,

    output reg         o_spi_sclk,
    output reg         o_spi_mosi,
    input  wire        i_spi_miso,
    output reg         o_spi_cs_n
);

    localparam [1:0] LP_REG_TXDATA = 2'd0;
    localparam [1:0] LP_REG_RXDATA = 2'd1;
    localparam [1:0] LP_REG_STATUS = 2'd2;
    localparam [1:0] LP_REG_CTRL   = 2'd3;

    localparam [1:0] LP_ST_IDLE  = 2'd0;
    localparam [1:0] LP_ST_LEAD  = 2'd1;
    localparam [1:0] LP_ST_TRAIL = 2'd2;
    localparam [1:0] LP_ST_DONE  = 2'd3;

    wire [1:0] w_reg_sel = i_addr[3:2];

    reg        reg_en;
    reg        reg_cpol;
    reg        reg_cpha;
    reg        reg_cs_auto;
    reg        reg_cs_manual;
    reg [7:0]  reg_clkdiv;

    reg [1:0]  reg_state;
    reg [7:0]  reg_tx_shift;
    reg [7:0]  reg_rx_shift;
    reg [7:0]  reg_rx_data;
    reg        reg_rx_valid;
    reg [7:0]  reg_div_cnt;
    reg [2:0]  reg_bit_cnt;

    wire w_busy = (reg_state != LP_ST_IDLE);

    assign o_ready = i_req;

    always @(*) begin : p_read
        o_rdata = 32'd0;
        if (!i_we) begin
            case (w_reg_sel)
                LP_REG_RXDATA: o_rdata = {24'd0, reg_rx_data};
                LP_REG_STATUS: o_rdata = {30'd0, reg_rx_valid, w_busy};
                LP_REG_CTRL  : o_rdata = {16'd0, reg_clkdiv, 3'd0,
                                          reg_cs_manual, reg_cs_auto,
                                          reg_cpha, reg_cpol, reg_en};
                default      : o_rdata = 32'd0;
            endcase
        end
    end

    always @(posedge i_clk or negedge i_resetn) begin : p_spi
        if (!i_resetn) begin
            reg_en        <= 1'b0;
            reg_cpol      <= 1'b0;
            reg_cpha      <= 1'b0;
            reg_cs_auto   <= 1'b1;
            reg_cs_manual <= 1'b1;
            reg_clkdiv    <= 8'd3;

            reg_state     <= LP_ST_IDLE;
            reg_tx_shift  <= 8'd0;
            reg_rx_shift  <= 8'd0;
            reg_rx_data   <= 8'd0;
            reg_rx_valid  <= 1'b0;
            reg_div_cnt   <= 8'd0;
            reg_bit_cnt   <= 3'd0;

            o_spi_sclk    <= 1'b0;
            o_spi_mosi    <= 1'b0;
            o_spi_cs_n    <= 1'b1;
        end else begin
            if (i_req && !i_we && (w_reg_sel == LP_REG_RXDATA)) begin
                reg_rx_valid <= 1'b0;
            end

            if (i_req && i_we && (w_reg_sel == LP_REG_CTRL) && !w_busy) begin
                reg_en        <= i_wdata[0];
                reg_cpol      <= i_wdata[1];
                reg_cpha      <= i_wdata[2];
                reg_cs_auto   <= i_wdata[3];
                reg_cs_manual <= i_wdata[4];
                reg_clkdiv    <= i_wdata[15:8];
                o_spi_sclk    <= i_wdata[1];
                o_spi_cs_n    <= i_wdata[3] ? 1'b1 : i_wdata[4];
            end

            case (reg_state)
                LP_ST_IDLE: begin
                    o_spi_sclk <= reg_cpol;
                    o_spi_cs_n <= reg_cs_auto ? 1'b1 : reg_cs_manual;
                    if (i_req && i_we && (w_reg_sel == LP_REG_TXDATA) && reg_en) begin
                        reg_tx_shift <= i_wdata[7:0];
                        reg_rx_shift <= 8'd0;
                        reg_bit_cnt  <= 3'd7;
                        reg_div_cnt  <= 8'd0;
                        if (reg_cs_auto) begin
                            o_spi_cs_n <= 1'b0;
                        end
                        if (!reg_cpha) begin
                            o_spi_mosi <= i_wdata[7];
                        end
                        reg_state <= LP_ST_LEAD;
                    end
                end

                LP_ST_LEAD: begin
                    if (reg_div_cnt >= reg_clkdiv) begin
                        reg_div_cnt <= 8'd0;
                        o_spi_sclk  <= ~reg_cpol;
                        if (!reg_cpha) begin
                            reg_rx_shift <= {reg_rx_shift[6:0], i_spi_miso};
                        end else begin
                            o_spi_mosi   <= reg_tx_shift[7];
                            reg_tx_shift <= {reg_tx_shift[6:0], 1'b0};
                        end
                        reg_state <= LP_ST_TRAIL;
                    end else begin
                        reg_div_cnt <= reg_div_cnt + 8'd1;
                    end
                end

                LP_ST_TRAIL: begin
                    if (reg_div_cnt >= reg_clkdiv) begin
                        reg_div_cnt <= 8'd0;
                        o_spi_sclk  <= reg_cpol;
                        if (reg_cpha) begin
                            reg_rx_shift <= {reg_rx_shift[6:0], i_spi_miso};
                            if (reg_bit_cnt == 3'd0) begin
                                reg_rx_data  <= {reg_rx_shift[6:0], i_spi_miso};
                                reg_rx_valid <= 1'b1;
                                reg_state    <= LP_ST_DONE;
                            end else begin
                                reg_bit_cnt <= reg_bit_cnt - 3'd1;
                                reg_state   <= LP_ST_LEAD;
                            end
                        end else begin
                            o_spi_mosi   <= reg_tx_shift[6];
                            reg_tx_shift <= {reg_tx_shift[6:0], 1'b0};
                            if (reg_bit_cnt == 3'd0) begin
                                reg_rx_data  <= reg_rx_shift;
                                reg_rx_valid <= 1'b1;
                                reg_state    <= LP_ST_DONE;
                            end else begin
                                reg_bit_cnt <= reg_bit_cnt - 3'd1;
                                reg_state   <= LP_ST_LEAD;
                            end
                        end
                    end else begin
                        reg_div_cnt <= reg_div_cnt + 8'd1;
                    end
                end

                LP_ST_DONE: begin
                    if (reg_div_cnt >= reg_clkdiv) begin
                        reg_div_cnt <= 8'd0;
                        if (reg_cs_auto) begin
                            o_spi_cs_n <= 1'b1;
                        end
                        reg_state <= LP_ST_IDLE;
                    end else begin
                        reg_div_cnt <= reg_div_cnt + 8'd1;
                    end
                end

                default: reg_state <= LP_ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
