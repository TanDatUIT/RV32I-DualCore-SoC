// =============================================================================
// Module      : soc_timer
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : 32-bit down-counter with reload, MMIO mapped.
//               0x00 CTRL  [0] enable, [1] periodic reload
//               0x04 LOAD  reload value
//               0x08 COUNT current value (read only)
// =============================================================================
`default_nettype none

module soc_timer (
    input  wire        i_clk,
    input  wire        i_resetn,

    input  wire        i_req,
    input  wire        i_we,
    input  wire [4:0]  i_addr,
    input  wire [31:0] i_wdata,

    output reg  [31:0] o_rdata,
    output wire        o_ready
);

    localparam [1:0] LP_REG_CTRL  = 2'd0;
    localparam [1:0] LP_REG_LOAD  = 2'd1;
    localparam [1:0] LP_REG_COUNT = 2'd2;

    reg [31:0] reg_load;
    reg [31:0] reg_cnt;
    reg        reg_en;
    reg        reg_periodic;

    wire [1:0] w_reg_sel = i_addr[3:2];

    assign o_ready = i_req;

    always @(*) begin : p_read
        o_rdata = 32'd0;
        if (!i_we) begin
            case (w_reg_sel)
                LP_REG_CTRL : o_rdata = {30'd0, reg_periodic, reg_en};
                LP_REG_LOAD : o_rdata = reg_load;
                LP_REG_COUNT: o_rdata = reg_cnt;
                default     : o_rdata = 32'd0;
            endcase
        end
    end

    always @(posedge i_clk or negedge i_resetn) begin : p_timer
        if (!i_resetn) begin
            reg_load     <= 32'd0;
            reg_cnt      <= 32'd0;
            reg_en       <= 1'b0;
            reg_periodic <= 1'b0;
        end else begin
            if (i_req && i_we) begin
                case (w_reg_sel)
                    LP_REG_CTRL: begin
                        reg_en       <= i_wdata[0];
                        reg_periodic <= i_wdata[1];
                        if (i_wdata[0]) begin
                            reg_cnt <= reg_load;
                        end
                    end
                    LP_REG_LOAD: begin
                        reg_load <= i_wdata;
                        reg_cnt  <= i_wdata;
                    end
                    default: begin
                        // LOAD/COUNT writes are ignored except above.
                    end
                endcase
            end else if (reg_en) begin
                if (reg_cnt == 32'd0) begin
                    if (reg_periodic) begin
                        reg_cnt <= reg_load;
                    end else begin
                        reg_en <= 1'b0;
                    end
                end else begin
                    reg_cnt <= reg_cnt - 32'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
