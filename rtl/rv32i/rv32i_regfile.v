// =============================================================================
// Module      : rv32i_regfile
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : 32 x 32-bit register file, 2 asynchronous read ports with
//               internal write-through bypass, 1 synchronous write port,
//               x0 hardwired to zero, async reset for GLS/Scan-DRC cleanliness.
// =============================================================================
`default_nettype none

module rv32i_regfile (
    input  wire        i_clk,
    input  wire        i_resetn,

    input  wire [4:0]  i_rs1_addr,
    output wire [31:0] o_rs1_data,

    input  wire [4:0]  i_rs2_addr,
    output wire [31:0] o_rs2_data,

    input  wire        i_wb_we,
    input  wire [4:0]  i_wb_addr,
    input  wire [31:0] i_wb_data
);

    reg [31:0] reg_rf [1:31];

    integer k;

    // Asynchronous read with internal WB-to-ID bypass to resolve distance-3 RAW hazards
    assign o_rs1_data = (i_rs1_addr == 5'd0) ? 32'd0 :
                        (i_wb_we && (i_wb_addr == i_rs1_addr)) ? i_wb_data :
                        reg_rf[i_rs1_addr];

    assign o_rs2_data = (i_rs2_addr == 5'd0) ? 32'd0 :
                        (i_wb_we && (i_wb_addr == i_rs2_addr)) ? i_wb_data :
                        reg_rf[i_rs2_addr];

    always @(posedge i_clk or negedge i_resetn) begin : p_rf_write
        if (!i_resetn) begin
            for (k = 1; k < 32; k = k + 1) begin
                reg_rf[k] <= 32'd0;
            end
        end else if (i_wb_we && (i_wb_addr != 5'd0)) begin
            reg_rf[i_wb_addr] <= i_wb_data;
        end
    end

endmodule

`default_nettype wire
