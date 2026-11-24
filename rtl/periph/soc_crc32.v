// =============================================================================
// Module      : soc_crc32
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : Hardware IEEE 802.3 CRC-32 accelerator (reflected poly
//               0xEDB88320, init 0xFFFFFFFF, final XOR 0xFFFFFFFF).
//               DATA_BYTE completes in 1 cycle; DATA_WORD sequences 4 bytes
//               (LSB first) through a single 8-bit combinational CRC step unit.
//
// Register map (Base 0x2000_0300, byte offsets):
//   0x00 CTRL      [0] INIT (W1P resets accumulator to 0xFFFFFFFF)
//   0x04 DATA_BYTE [7:0] feed 1 byte (W)
//   0x08 DATA_WORD [31:0] feed 4 bytes little-endian, stalls 4 cycles (W)
//   0x0C RESULT    [31:0] finalized CRC32 = ~raw (RO)
//   0x10 RAW       [31:0] internal CRC register (RO)
// =============================================================================
`default_nettype none

module soc_crc32 (
    input  wire        i_clk,
    input  wire        i_resetn,

    input  wire        i_req,
    input  wire        i_we,
    input  wire [4:0]  i_addr,
    input  wire [31:0] i_wdata,

    output reg  [31:0] o_rdata,
    output wire        o_ready
);

    localparam [2:0] LP_REG_CTRL      = 3'd0;
    localparam [2:0] LP_REG_DATA_BYTE = 3'd1;
    localparam [2:0] LP_REG_DATA_WORD = 3'd2;
    localparam [2:0] LP_REG_RESULT    = 3'd3;
    localparam [2:0] LP_REG_RAW       = 3'd4;

    localparam [1:0] LP_ST_IDLE = 2'd0;
    localparam [1:0] LP_ST_B1   = 2'd1;
    localparam [1:0] LP_ST_B2   = 2'd2;
    localparam [1:0] LP_ST_B3   = 2'd3;

    localparam [31:0] LP_CRC_POLY = 32'hEDB8_8320;

    wire [2:0] w_reg_sel = i_addr[4:2];

    reg [31:0] reg_crc;
    reg [1:0]  reg_state;

    function [31:0] f_crc32_byte;
        input [31:0] f_crc_in;
        input [7:0]  f_byte_in;
        reg   [31:0] v_crc;
        integer      b;
        begin
            v_crc = f_crc_in ^ {24'd0, f_byte_in};
            for (b = 0; b < 8; b = b + 1) begin
                if (v_crc[0]) begin
                    v_crc = (v_crc >> 1) ^ LP_CRC_POLY;
                end else begin
                    v_crc = (v_crc >> 1);
                end
            end
            f_crc32_byte = v_crc;
        end
    endfunction

    wire w_word_wr = i_req && i_we && (w_reg_sel == LP_REG_DATA_WORD);

    reg [7:0] w_feed_byte;

    always @(*) begin : p_crc_feed
        w_feed_byte = i_wdata[7:0];
        case (reg_state)
            LP_ST_IDLE: w_feed_byte = i_wdata[7:0];
            LP_ST_B1  : w_feed_byte = i_wdata[15:8];
            LP_ST_B2  : w_feed_byte = i_wdata[23:16];
            LP_ST_B3  : w_feed_byte = i_wdata[31:24];
            default   : w_feed_byte = i_wdata[7:0];
        endcase
    end

    wire [31:0] w_crc_next = f_crc32_byte(reg_crc, w_feed_byte);

    // 1-cycle ready except DATA_WORD write which completes on LP_ST_B3
    assign o_ready = (reg_state == LP_ST_B3) ||
                     ((reg_state == LP_ST_IDLE) && i_req && !w_word_wr);

    always @(*) begin : p_read
        o_rdata = 32'd0;
        if (!i_we) begin
            case (w_reg_sel)
                LP_REG_RESULT: o_rdata = reg_crc ^ 32'hFFFF_FFFF;
                LP_REG_RAW   : o_rdata = reg_crc;
                default      : o_rdata = 32'd0;
            endcase
        end
    end

    always @(posedge i_clk or negedge i_resetn) begin : p_crc
        if (!i_resetn) begin
            reg_crc   <= 32'hFFFF_FFFF;
            reg_state <= LP_ST_IDLE;
        end else begin
            case (reg_state)
                LP_ST_IDLE: begin
                    if (i_req && i_we) begin
                        if (w_reg_sel == LP_REG_CTRL) begin
                            if (i_wdata[0]) begin
                                reg_crc <= 32'hFFFF_FFFF;
                            end
                        end else if (w_reg_sel == LP_REG_DATA_BYTE) begin
                            reg_crc <= w_crc_next;
                        end else if (w_reg_sel == LP_REG_DATA_WORD) begin
                            reg_crc   <= w_crc_next;
                            reg_state <= LP_ST_B1;
                        end
                    end
                end

                LP_ST_B1: begin
                    reg_crc   <= w_crc_next;
                    reg_state <= LP_ST_B2;
                end

                LP_ST_B2: begin
                    reg_crc   <= w_crc_next;
                    reg_state <= LP_ST_B3;
                end

                LP_ST_B3: begin
                    reg_crc   <= w_crc_next;
                    reg_state <= LP_ST_IDLE;
                end

                default: reg_state <= LP_ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
