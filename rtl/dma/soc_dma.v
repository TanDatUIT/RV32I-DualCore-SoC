// =============================================================================
// Module      : soc_dma
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : Single-channel 32-bit word DMA engine with MMIO slave control
//               and bus master port (SRAM <-> SRAM / NPU / Peripherals).
//
// Register map (Base 0x1000_0100, byte offsets):
//   0x00 CTRL      [0] start (W1P), [1] src_inc (RW), [2] dst_inc (RW)
//   0x04 STATUS    [0] busy (RO), [1] done (sticky, cleared on STATUS read/start)
//   0x08 SRC_ADDR  [31:0] word-aligned source address
//   0x0C DST_ADDR  [31:0] word-aligned destination address
//   0x10 LEN_WORDS [9:0] transfer count in 32-bit words
// =============================================================================
`default_nettype none

module soc_dma (
    input  wire        i_clk,
    input  wire        i_resetn,
    input  wire        i_soft_rst,

    // Slave MMIO interface
    input  wire        i_req,
    input  wire        i_we,
    input  wire [7:0]  i_addr,
    input  wire [31:0] i_wdata,
    output reg  [31:0] o_rdata,
    output wire        o_ready,

    // Master bus interface
    output wire        o_dma_req,
    output wire        o_dma_we,
    output wire [3:0]  o_dma_be,
    output wire [31:0] o_dma_addr,
    output wire [31:0] o_dma_wdata,
    input  wire [31:0] i_dma_rdata,
    input  wire        i_dma_ready
);

    localparam [2:0] LP_REG_CTRL      = 3'd0;
    localparam [2:0] LP_REG_STATUS    = 3'd1;
    localparam [2:0] LP_REG_SRC_ADDR  = 3'd2;
    localparam [2:0] LP_REG_DST_ADDR  = 3'd3;
    localparam [2:0] LP_REG_LEN_WORDS = 3'd4;

    localparam [1:0] LP_ST_IDLE = 2'd0;
    localparam [1:0] LP_ST_RD   = 2'd1;
    localparam [1:0] LP_ST_WR   = 2'd2;

    wire [2:0] w_reg_sel = i_addr[4:2];

    reg [1:0]  reg_state;
    reg [31:0] reg_src_addr;
    reg [31:0] reg_dst_addr;
    reg [9:0]  reg_len_words;
    reg        reg_src_inc;
    reg        reg_dst_inc;
    reg        reg_done;

    reg [31:0] reg_cur_src;
    reg [31:0] reg_cur_dst;
    reg [9:0]  reg_rem;
    reg [31:0] reg_buf;

    wire w_busy = (reg_state != LP_ST_IDLE);

    assign o_ready     = i_req;
    assign o_dma_req   = !i_soft_rst && ((reg_state == LP_ST_RD) || (reg_state == LP_ST_WR));
    assign o_dma_we    = (reg_state == LP_ST_WR);
    assign o_dma_be    = 4'b1111;
    assign o_dma_addr  = (reg_state == LP_ST_WR) ? {reg_cur_dst[31:2], 2'b00}
                                                 : {reg_cur_src[31:2], 2'b00};
    assign o_dma_wdata = reg_buf;

    always @(*) begin : p_read
        o_rdata = 32'd0;
        if (!i_we) begin
            case (w_reg_sel)
                LP_REG_CTRL     : o_rdata = {29'd0, reg_dst_inc, reg_src_inc, 1'b0};
                LP_REG_STATUS   : o_rdata = {30'd0, reg_done, w_busy};
                LP_REG_SRC_ADDR : o_rdata = reg_src_addr;
                LP_REG_DST_ADDR : o_rdata = reg_dst_addr;
                LP_REG_LEN_WORDS: o_rdata = {22'd0, reg_len_words};
                default         : o_rdata = 32'd0;
            endcase
        end
    end

    always @(posedge i_clk or negedge i_resetn) begin : p_dma
        if (!i_resetn) begin
            reg_state     <= LP_ST_IDLE;
            reg_src_addr  <= 32'd0;
            reg_dst_addr  <= 32'd0;
            reg_len_words <= 10'd0;
            reg_src_inc   <= 1'b1;
            reg_dst_inc   <= 1'b1;
            reg_done      <= 1'b0;
            reg_cur_src   <= 32'd0;
            reg_cur_dst   <= 32'd0;
            reg_rem       <= 10'd0;
            reg_buf       <= 32'd0;
        end else if (i_soft_rst) begin
            reg_state     <= LP_ST_IDLE;
            reg_rem       <= 10'd0;
            reg_done      <= 1'b0;
        end else begin
            // Clear sticky done on STATUS read (only when idle or not finishing simultaneously)
            if (i_req && !i_we && (w_reg_sel == LP_REG_STATUS)) begin
                reg_done <= 1'b0;
            end

            // Configuration writes only accepted when idle
            if (i_req && i_we && !w_busy) begin
                case (w_reg_sel)
                    LP_REG_CTRL: begin
                        reg_src_inc <= i_wdata[1];
                        reg_dst_inc <= i_wdata[2];
                        if (i_wdata[0]) begin
                            reg_done <= 1'b0;
                            if (reg_len_words == 10'd0) begin
                                reg_done <= 1'b1;
                            end else begin
                                reg_cur_src <= reg_src_addr;
                                reg_cur_dst <= reg_dst_addr;
                                reg_rem     <= reg_len_words;
                                reg_state   <= LP_ST_RD;
                            end
                        end
                    end
                    LP_REG_SRC_ADDR : reg_src_addr  <= {i_wdata[31:2], 2'b00};
                    LP_REG_DST_ADDR : reg_dst_addr  <= {i_wdata[31:2], 2'b00};
                    LP_REG_LEN_WORDS: reg_len_words <= i_wdata[9:0];
                    default: ;
                endcase
            end

            // Transfer FSM
            case (reg_state)
                LP_ST_IDLE: begin
                end

                LP_ST_RD: begin
                    if (i_dma_ready) begin
                        reg_buf   <= i_dma_rdata;
                        reg_state <= LP_ST_WR;
                    end
                end

                LP_ST_WR: begin
                    if (i_dma_ready) begin
                        if (reg_src_inc) begin
                            reg_cur_src <= reg_cur_src + 32'd4;
                        end
                        if (reg_dst_inc) begin
                            reg_cur_dst <= reg_cur_dst + 32'd4;
                        end
                        if (reg_rem == 10'd1) begin
                            reg_rem   <= 10'd0;
                            reg_done  <= 1'b1;
                            reg_state <= LP_ST_IDLE;
                        end else begin
                            reg_rem   <= reg_rem - 10'd1;
                            reg_state <= LP_ST_RD;
                        end
                    end
                end

                default: reg_state <= LP_ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
