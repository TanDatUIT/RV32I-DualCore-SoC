// =============================================================================
// Module      : accel_wrapper
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : MMIO bus wrapper for the 4x4 systolic MAC array (Mini-NPU).
//               Implements diagonal systolic input skewing, overflow-free
//               4-bit step counter, edge-triggered sticky done flag, 4-byte
//               packed DMA-friendly writes, and post-processing (ReLU +
//               arithmetic right shift + INT8 saturation clamp).
//
// Register map (byte offsets, 32-bit accesses)
//   0x00 CTRL     [0] start (W1P), [1] clear (W1P)
//   0x04 STATUS   [0] busy, [1] done (sticky, cleared by reading STATUS/start)
//   0x08 A_IDX    [3:0] element index 0..15 (row*4 + col)
//   0x0C A_DATA   [7:0] signed element (auto-increments A_IDX)
//   0x10 B_IDX    [3:0] element index 0..15 (row*4 + col)
//   0x14 B_DATA   [7:0] signed element (auto-increments B_IDX)
//   0x18 R_IDX    [1:0] row, [3:2] column of result C[row][col]
//   0x1C R_DATA   [19:0] raw signed accumulator (sign-extended to 32-bit)
//   0x20 POST_CFG [0] relu_en, [4:1] shift (0..15), [5] clamp8_en
//   0x24 R_POST   [31:0] post-processed result (ReLU -> >>> shift -> clamp8)
//   0x28 A_PACK   [31:0] write 4 bytes {A[r][3],A[r][2],A[r][1],A[r][0]}, A_IDX+=4
//   0x2C B_PACK   [31:0] write 4 bytes {B[r][3],B[r][2],B[r][1],B[r][0]}, B_IDX+=4
// =============================================================================
`default_nettype none

module accel_wrapper (
    input  wire        i_clk,
    input  wire        i_resetn,

    input  wire        i_req,
    input  wire        i_we,
    input  wire [7:0]  i_addr,
    input  wire [31:0] i_wdata,

    output reg  [31:0] o_rdata,
    output wire        o_ready
);

    localparam [3:0] LP_REG_CTRL     = 4'h0;
    localparam [3:0] LP_REG_STATUS   = 4'h1;
    localparam [3:0] LP_REG_A_IDX    = 4'h2;
    localparam [3:0] LP_REG_A_DATA   = 4'h3;
    localparam [3:0] LP_REG_B_IDX    = 4'h4;
    localparam [3:0] LP_REG_B_DATA   = 4'h5;
    localparam [3:0] LP_REG_R_IDX    = 4'h6;
    localparam [3:0] LP_REG_R_DATA   = 4'h7;
    localparam [3:0] LP_REG_POST_CFG = 4'h8;
    localparam [3:0] LP_REG_R_POST   = 4'h9;
    localparam [3:0] LP_REG_A_PACK   = 4'hA;
    localparam [3:0] LP_REG_B_PACK   = 4'hB;

    localparam [1:0] LP_ST_IDLE  = 2'd0;
    localparam [1:0] LP_ST_CLEAR = 2'd1;
    localparam [1:0] LP_ST_START = 2'd2;
    localparam [1:0] LP_ST_RUN   = 2'd3;

    wire [3:0] w_reg_sel = i_addr[5:2];

    reg [7:0]  reg_mat_a [0:15];
    reg [7:0]  reg_mat_b [0:15];
    reg [3:0]  reg_idx_a;
    reg [3:0]  reg_idx_b;
    reg [3:0]  reg_idx_r;
    reg [3:0]  reg_step;
    reg [1:0]  reg_state;
    reg        reg_start;
    reg        reg_clear;
    reg        reg_done_sticky;
    reg        reg_accel_done_d;
    reg [3:0]  reg_row_sel;

    // Post-processing configuration
    reg        reg_relu_en;
    reg [3:0]  reg_shift;
    reg        reg_clamp8_en;

    integer    idx;

    wire       w_accel_busy;
    wire       w_accel_done;
    wire signed [19:0] w_res0;
    wire signed [19:0] w_res1;
    wire signed [19:0] w_res2;
    wire signed [19:0] w_res3;

    // -------------------------------------------------------------------------
    // Diagonal systolic input skewing:
    //   Row i of A enters at reg_step = i + k (k = 0..3)
    //   Col j of B enters at reg_step = j + k (k = 0..3)
    // So A[i][k] and B[k][j] meet at PE(i,j) at cycle i + j + k.
    // -------------------------------------------------------------------------
    wire w_a0_en = w_accel_busy && (reg_step <= 4'd3);
    wire w_a1_en = w_accel_busy && (reg_step >= 4'd1) && (reg_step <= 4'd4);
    wire w_a2_en = w_accel_busy && (reg_step >= 4'd2) && (reg_step <= 4'd5);
    wire w_a3_en = w_accel_busy && (reg_step >= 4'd3) && (reg_step <= 4'd6);

    wire [3:0] w_ak0 = reg_step;
    wire [3:0] w_ak1 = reg_step - 4'd1;
    wire [3:0] w_ak2 = reg_step - 4'd2;
    wire [3:0] w_ak3 = reg_step - 4'd3;

    wire signed [7:0] w_a0 = w_a0_en ? reg_mat_a[{2'd0, w_ak0[1:0]}] : 8'sd0;
    wire signed [7:0] w_a1 = w_a1_en ? reg_mat_a[{2'd1, w_ak1[1:0]}] : 8'sd0;
    wire signed [7:0] w_a2 = w_a2_en ? reg_mat_a[{2'd2, w_ak2[1:0]}] : 8'sd0;
    wire signed [7:0] w_a3 = w_a3_en ? reg_mat_a[{2'd3, w_ak3[1:0]}] : 8'sd0;

    wire signed [7:0] w_b0 = w_a0_en ? reg_mat_b[{w_ak0[1:0], 2'd0}] : 8'sd0;
    wire signed [7:0] w_b1 = w_a1_en ? reg_mat_b[{w_ak1[1:0], 2'd1}] : 8'sd0;
    wire signed [7:0] w_b2 = w_a2_en ? reg_mat_b[{w_ak2[1:0], 2'd2}] : 8'sd0;
    wire signed [7:0] w_b3 = w_a3_en ? reg_mat_b[{w_ak3[1:0], 2'd3}] : 8'sd0;

    accelerator_top u_accelerator (
        .clk      (i_clk),
        .rst_n    (i_resetn),
        .start    (reg_start),
        .clear    (reg_clear),
        .row_sel  (reg_row_sel),
        .a_row0   (w_a0),
        .a_row1   (w_a1),
        .a_row2   (w_a2),
        .a_row3   (w_a3),
        .b_col0   (w_b0),
        .b_col1   (w_b1),
        .b_col2   (w_b2),
        .b_col3   (w_b3),
        .res_out0 (w_res0),
        .res_out1 (w_res1),
        .res_out2 (w_res2),
        .res_out3 (w_res3),
        .busy     (w_accel_busy),
        .done     (w_accel_done)
    );

    // Result column mux
    wire signed [19:0] w_res_col = (reg_idx_r[3:2] == 2'd0) ? w_res0 :
                                   (reg_idx_r[3:2] == 2'd1) ? w_res1 :
                                   (reg_idx_r[3:2] == 2'd2) ? w_res2 : w_res3;

    // -------------------------------------------------------------------------
    // Post-processing datapath: ReLU -> arithmetic right shift -> INT8 clamp
    // -------------------------------------------------------------------------
    wire signed [19:0] w_post_relu  = (reg_relu_en && w_res_col[19]) ? 20'sd0 : w_res_col;
    wire signed [19:0] w_post_shift = w_post_relu >>> reg_shift;
    wire signed [19:0] w_post_clamp =
        (reg_clamp8_en && (w_post_shift > 20'sd127))  ? 20'sd127  :
        (reg_clamp8_en && (w_post_shift < -20'sd128)) ? -20'sd128 :
                                                        w_post_shift;

    assign o_ready = i_req;

    // -------------------------------------------------------------------------
    // Read mux
    // -------------------------------------------------------------------------
    always @(*) begin : p_read
        o_rdata = 32'd0;
        if (!i_we) begin
            case (w_reg_sel)
                LP_REG_STATUS  : o_rdata = {30'd0, reg_done_sticky, w_accel_busy};
                LP_REG_A_IDX   : o_rdata = {28'd0, reg_idx_a};
                LP_REG_A_DATA  : o_rdata = {24'd0, reg_mat_a[reg_idx_a]};
                LP_REG_B_IDX   : o_rdata = {28'd0, reg_idx_b};
                LP_REG_B_DATA  : o_rdata = {24'd0, reg_mat_b[reg_idx_b]};
                LP_REG_R_IDX   : o_rdata = {28'd0, reg_idx_r};
                LP_REG_R_DATA  : o_rdata = {{12{w_res_col[19]}}, w_res_col};
                LP_REG_POST_CFG: o_rdata = {26'd0, reg_clamp8_en, reg_shift, reg_relu_en};
                LP_REG_R_POST  : o_rdata = {{12{w_post_clamp[19]}}, w_post_clamp};
                default        : o_rdata = 32'd0;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Register writes / FSM
    // -------------------------------------------------------------------------
    wire w_done_rise = w_accel_done && !reg_accel_done_d;

    always @(posedge i_clk or negedge i_resetn) begin : p_accel_wrap
        if (!i_resetn) begin
            for (idx = 0; idx < 16; idx = idx + 1) begin
                reg_mat_a[idx] <= 8'd0;
                reg_mat_b[idx] <= 8'd0;
            end
            reg_idx_a        <= 4'd0;
            reg_idx_b        <= 4'd0;
            reg_idx_r        <= 4'd0;
            reg_step         <= 4'd0;
            reg_state        <= LP_ST_IDLE;
            reg_start        <= 1'b0;
            reg_clear        <= 1'b0;
            reg_done_sticky  <= 1'b0;
            reg_accel_done_d <= 1'b0;
            reg_row_sel      <= 4'b0001;
            reg_relu_en      <= 1'b0;
            reg_shift        <= 4'd0;
            reg_clamp8_en    <= 1'b0;
        end else begin
            reg_start        <= 1'b0;
            reg_clear        <= 1'b0;
            reg_accel_done_d <= w_accel_done;

            if (w_accel_busy) begin
                reg_step <= reg_step + 4'd1;
            end else begin
                reg_step <= 4'd0;
            end

            // Sticky done flag set only on rising edge of done
            if (w_done_rise) begin
                reg_done_sticky <= 1'b1;
            end else if (i_req && !i_we && (w_reg_sel == LP_REG_STATUS)) begin
                reg_done_sticky <= 1'b0;
            end

            // MMIO register writes
            if (i_req && i_we) begin
                case (w_reg_sel)
                    LP_REG_CTRL: begin
                        if (i_wdata[0] && (reg_state == LP_ST_IDLE)) begin
                            reg_done_sticky <= 1'b0;
                            reg_state       <= LP_ST_CLEAR;
                        end else if (i_wdata[1] && (reg_state == LP_ST_IDLE)) begin
                            reg_clear       <= 1'b1;
                            reg_done_sticky <= 1'b0;
                        end
                    end
                    LP_REG_A_IDX: reg_idx_a <= i_wdata[3:0];
                    LP_REG_A_DATA: begin
                        reg_mat_a[reg_idx_a] <= i_wdata[7:0];
                        reg_idx_a            <= reg_idx_a + 4'd1;
                    end
                    LP_REG_B_IDX: reg_idx_b <= i_wdata[3:0];
                    LP_REG_B_DATA: begin
                        reg_mat_b[reg_idx_b] <= i_wdata[7:0];
                        reg_idx_b            <= reg_idx_b + 4'd1;
                    end
                    LP_REG_R_IDX: begin
                        reg_idx_r   <= i_wdata[3:0];
                        reg_row_sel <= 4'b0001 << i_wdata[1:0];
                    end
                    LP_REG_POST_CFG: begin
                        reg_relu_en   <= i_wdata[0];
                        reg_shift     <= i_wdata[4:1];
                        reg_clamp8_en <= i_wdata[5];
                    end
                    LP_REG_A_PACK: begin
                        reg_mat_a[{reg_idx_a[3:2], 2'd0}] <= i_wdata[7:0];
                        reg_mat_a[{reg_idx_a[3:2], 2'd1}] <= i_wdata[15:8];
                        reg_mat_a[{reg_idx_a[3:2], 2'd2}] <= i_wdata[23:16];
                        reg_mat_a[{reg_idx_a[3:2], 2'd3}] <= i_wdata[31:24];
                        reg_idx_a <= reg_idx_a + 4'd4;
                    end
                    LP_REG_B_PACK: begin
                        reg_mat_b[{reg_idx_b[3:2], 2'd0}] <= i_wdata[7:0];
                        reg_mat_b[{reg_idx_b[3:2], 2'd1}] <= i_wdata[15:8];
                        reg_mat_b[{reg_idx_b[3:2], 2'd2}] <= i_wdata[23:16];
                        reg_mat_b[{reg_idx_b[3:2], 2'd3}] <= i_wdata[31:24];
                        reg_idx_b <= reg_idx_b + 4'd4;
                    end
                    default: begin
                        // Read-only or reserved registers
                    end
                endcase
            end

            // Sequencer for accelerator_top
            case (reg_state)
                LP_ST_IDLE: begin
                end
                LP_ST_CLEAR: begin
                    reg_clear <= 1'b1;
                    reg_state <= LP_ST_START;
                end
                LP_ST_START: begin
                    reg_clear <= 1'b0;
                    reg_start <= 1'b1;
                    reg_state <= LP_ST_RUN;
                end
                LP_ST_RUN: begin
                    if (w_done_rise) begin
                        reg_state <= LP_ST_IDLE;
                    end
                end
                default: reg_state <= LP_ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
