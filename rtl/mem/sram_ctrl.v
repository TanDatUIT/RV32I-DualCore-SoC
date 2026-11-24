// =============================================================================
// Module      : sram_ctrl
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : Bus slave that adapts the 1RW hard macro sram_2k_macro
//               (1024 x 32-bit, CEN/WEN active-low, no byte enables) to the
//               SoC byte-enable write protocol.
//
//               * read        : 2-cycle latency (LP_IDLE -> LP_RD_RSP)
//               * word write  : 2-cycle latency (LP_IDLE -> LP_WR_RSP)
//               * byte / half : 4-cycle read-modify-write
// =============================================================================
`default_nettype none

module sram_ctrl (
    input  wire        i_clk,
    input  wire        i_resetn,

    input  wire        i_req,
    input  wire        i_we,
    input  wire [3:0]  i_be,
    input  wire [11:0] i_addr,
    input  wire [31:0] i_wdata,

    output wire [31:0] o_rdata,
    output wire        o_ready
);

    localparam [2:0] LP_IDLE    = 3'd0;
    localparam [2:0] LP_RD_RSP  = 3'd1;
    localparam [2:0] LP_WR_RSP  = 3'd2;
    localparam [2:0] LP_RMW_MRG = 3'd3;
    localparam [2:0] LP_RMW_WR  = 3'd4;

    reg [2:0]  reg_state;
    reg [9:0]  reg_addr;
    reg [31:0] reg_wdata;
    reg [3:0]  reg_be;
    reg [31:0] reg_mdata;

    wire w_word_write = i_we && (i_be == 4'b1111);
    wire w_byte_write = i_we && (i_be != 4'b1111);

    wire        w_macro_cen = ((reg_state == LP_IDLE) && i_req) ||
                              (reg_state == LP_RMW_WR);
    wire        w_macro_wen = ((reg_state == LP_IDLE) && i_req && w_word_write) ? 1'b0 :
                              (reg_state == LP_RMW_WR) ? 1'b0 : 1'b1;
    wire [9:0]  w_macro_a   = (reg_state == LP_RMW_WR) ? reg_addr  : i_addr[11:2];
    wire [31:0] w_macro_d   = (reg_state == LP_RMW_WR) ? reg_mdata : i_wdata;

    wire [31:0] w_macro_q;

    sram_2k_macro u_sram_macro (
        .CLK (i_clk),
        .CEN (~w_macro_cen),
        .WEN (w_macro_wen),
        .A   (w_macro_a),
        .D   (w_macro_d),
        .Q   (w_macro_q)
    );

    // Byte-lane merge for sub-word RMW
    reg [31:0] w_merged;
    always @(*) begin : p_merge
        w_merged = w_macro_q;
        if (reg_be[0]) w_merged[7:0]   = reg_wdata[7:0];
        if (reg_be[1]) w_merged[15:8]  = reg_wdata[15:8];
        if (reg_be[2]) w_merged[23:16] = reg_wdata[23:16];
        if (reg_be[3]) w_merged[31:24] = reg_wdata[31:24];
    end

    assign o_ready = (reg_state == LP_RD_RSP) || (reg_state == LP_WR_RSP);
    assign o_rdata = (reg_state == LP_RD_RSP) ? w_macro_q : 32'd0;

    always @(posedge i_clk or negedge i_resetn) begin : p_sram_ctrl
        if (!i_resetn) begin
            reg_state <= LP_IDLE;
            reg_addr  <= 10'd0;
            reg_wdata <= 32'd0;
            reg_be    <= 4'd0;
            reg_mdata <= 32'd0;
        end else begin
            case (reg_state)
                LP_IDLE: begin
                    if (i_req) begin
                        reg_addr  <= i_addr[11:2];
                        reg_wdata <= i_wdata;
                        reg_be    <= i_be;
                        if (!i_we) begin
                            reg_state <= LP_RD_RSP;
                        end else if (w_word_write) begin
                            reg_state <= LP_WR_RSP;
                        end else if (w_byte_write) begin
                            reg_state <= LP_RMW_MRG;
                        end else begin
                            reg_state <= LP_WR_RSP;
                        end
                    end
                end

                LP_RD_RSP: begin
                    reg_state <= LP_IDLE;
                end

                LP_WR_RSP: begin
                    reg_state <= LP_IDLE;
                end

                LP_RMW_MRG: begin
                    reg_mdata <= w_merged;
                    reg_state <= LP_RMW_WR;
                end

                LP_RMW_WR: begin
                    reg_state <= LP_WR_RSP;
                end

                default: reg_state <= LP_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
