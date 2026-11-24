// =============================================================================
// Module      : soc_gpio
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : 16-bit GPIO, MMIO mapped.
//               0x00 DATA_IN  (R)  pin level
//               0x04 DATA_OUT (RW) output register
//               0x08 OE       (RW) output enable
// =============================================================================
`default_nettype none

module soc_gpio (
    input  wire        i_clk,
    input  wire        i_resetn,

    input  wire        i_req,
    input  wire        i_we,
    input  wire [4:0]  i_addr,
    input  wire [31:0] i_wdata,

    output reg  [31:0] o_rdata,
    output wire        o_ready,

    input  wire [15:0] i_gpio_in,
    output reg  [15:0] o_gpio_out,
    output reg  [15:0] o_gpio_oe
);

    localparam [1:0] LP_REG_IN  = 2'd0;
    localparam [1:0] LP_REG_OUT = 2'd1;
    localparam [1:0] LP_REG_OE  = 2'd2;

    wire [1:0] w_reg_sel = i_addr[3:2];

    reg [15:0] reg_gpio_in_sync1;
    reg [15:0] reg_gpio_in_sync2;

    assign o_ready = i_req;

    always @(*) begin : p_read
        o_rdata = 32'd0;
        if (!i_we) begin
            case (w_reg_sel)
                LP_REG_IN : o_rdata = {16'd0, reg_gpio_in_sync2};
                LP_REG_OUT: o_rdata = {16'd0, o_gpio_out};
                LP_REG_OE : o_rdata = {16'd0, o_gpio_oe};
                default   : o_rdata = 32'd0;
            endcase
        end
    end

    always @(posedge i_clk or negedge i_resetn) begin : p_gpio
        if (!i_resetn) begin
            reg_gpio_in_sync1 <= 16'd0;
            reg_gpio_in_sync2 <= 16'd0;
            o_gpio_out        <= 16'd0;
            o_gpio_oe         <= 16'd0;
        end else begin
            reg_gpio_in_sync1 <= i_gpio_in;
            reg_gpio_in_sync2 <= reg_gpio_in_sync1;
            if (i_req && i_we) begin
                case (w_reg_sel)
                    LP_REG_OUT: o_gpio_out <= i_wdata[15:0];
                    LP_REG_OE : o_gpio_oe  <= i_wdata[15:0];
                    default   : begin
                        // read-only register, writes ignored
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire
