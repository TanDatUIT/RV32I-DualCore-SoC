// =============================================================================
// Module      : rv32i_alu
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : 32-bit combinational ALU for the RV32I core.
//               Optimized architecture:
//               1. Shared 33-bit adder/subtractor/comparator (unifies ADD, SUB, SLT, SLTU)
//               2. Shared 64-bit right shifter with zero-cost bit-reversal wiring
//                  (unifies SLL, SRL, SRA into a single barrel shifter)
// =============================================================================
`default_nettype none

module rv32i_alu (
    input  wire [3:0]  i_alu_op,
    input  wire [31:0] i_op_a,
    input  wire [31:0] i_op_b,
    output reg  [31:0] o_result
);

    localparam [3:0] LP_ALU_ADD  = 4'd0;
    localparam [3:0] LP_ALU_SUB  = 4'd1;
    localparam [3:0] LP_ALU_SLL  = 4'd2;
    localparam [3:0] LP_ALU_SLT  = 4'd3;
    localparam [3:0] LP_ALU_SLTU = 4'd4;
    localparam [3:0] LP_ALU_XOR  = 4'd5;
    localparam [3:0] LP_ALU_SRL  = 4'd6;
    localparam [3:0] LP_ALU_SRA  = 4'd7;
    localparam [3:0] LP_ALU_OR   = 4'd8;
    localparam [3:0] LP_ALU_AND  = 4'd9;
    localparam [3:0] LP_ALU_PASS = 4'd10;

    // -------------------------------------------------------------------------
    // 1. Shared 33-bit Adder/Subtractor and Comparator Unit
    // Unifies ADD, SUB, SLT, SLTU onto a single adder to eliminate redundant
    // arithmetic datapath operators and minimize cell area / fanout.
    // -------------------------------------------------------------------------
    wire        w_is_sub = (i_alu_op == LP_ALU_SUB)  ||
                           (i_alu_op == LP_ALU_SLT)  ||
                           (i_alu_op == LP_ALU_SLTU);
    wire [31:0] w_b_inv  = w_is_sub ? ~i_op_b : i_op_b;
    wire [32:0] w_adder  = {1'b0, i_op_a} + {1'b0, w_b_inv} + {32'd0, w_is_sub};

    // SLT (signed comparison):
    // Different signs: op_a < op_b iff op_a is negative (i_op_a[31] == 1)
    // Same signs: op_a < op_b iff (op_a - op_b) is negative (w_adder[31] == 1)
    wire w_slt = (i_op_a[31] != i_op_b[31]) ? i_op_a[31] : w_adder[31];

    // SLTU (unsigned comparison):
    // op_a < op_b iff carry-out from (op_a + ~op_b + 1) is 0
    wire w_sltu = ~w_adder[32];

    // -------------------------------------------------------------------------
    // 2. Shared Shifter Unit (SLL, SRL, SRA)
    // SLL(a, shamt) is mathematically equivalent to rev(rev(a) >> shamt).
    // In silicon, bit reversal is zero-cost routing wires (0 gates, 0 delay).
    // -------------------------------------------------------------------------
    genvar gi;
    wire [31:0] w_op_a_rev;
    for (gi = 0; gi < 32; gi = gi + 1) begin : g_rev_in
        assign w_op_a_rev[gi] = i_op_a[31 - gi];
    end

    wire [31:0] w_shift_in   = (i_alu_op == LP_ALU_SLL) ? w_op_a_rev : i_op_a;
    wire        w_shift_sign = (i_alu_op == LP_ALU_SRA) ? i_op_a[31] : 1'b0;

    wire [63:0] w_shift_ext  = {{32{w_shift_sign}}, w_shift_in};
    wire [63:0] w_shifted    = w_shift_ext >> i_op_b[4:0];
    wire [31:0] w_rshift_out = w_shifted[31:0];

    wire [31:0] w_lshift_out;
    for (gi = 0; gi < 32; gi = gi + 1) begin : g_rev_out
        assign w_lshift_out[gi] = w_rshift_out[31 - gi];
    end

    wire [31:0] w_shift_res = (i_alu_op == LP_ALU_SLL) ? w_lshift_out : w_rshift_out;

    // -------------------------------------------------------------------------
    // 3. Result Multiplexer
    // -------------------------------------------------------------------------
    always @(*) begin : p_alu
        case (i_alu_op)
            LP_ALU_ADD : o_result = w_adder[31:0];
            LP_ALU_SUB : o_result = w_adder[31:0];
            LP_ALU_SLL : o_result = w_shift_res;
            LP_ALU_SLT : o_result = {31'd0, w_slt};
            LP_ALU_SLTU: o_result = {31'd0, w_sltu};
            LP_ALU_XOR : o_result = i_op_a ^ i_op_b;
            LP_ALU_SRL : o_result = w_shift_res;
            LP_ALU_SRA : o_result = w_shift_res;
            LP_ALU_OR  : o_result = i_op_a | i_op_b;
            LP_ALU_AND : o_result = i_op_a & i_op_b;
            LP_ALU_PASS: o_result = i_op_b;
            default    : o_result = i_op_b;
        endcase
    end

endmodule

`default_nettype wire
