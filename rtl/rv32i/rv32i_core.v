// =============================================================================
// Module      : rv32i_core
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : Single-master RISC-V RV32I core, classic 5-stage pipeline
//               IF -> ID -> EX -> MEM -> WB with full forwarding, load-use
//               interlock, branch/jump flush, synchronous watchdog reset and
//               a valid/ready Harvard memory interface.
//
// Address map note: the core itself is position independent; the SoC bus
// maps the 4 KB I-SRAM at 0x0000_0000, so PC resets to 0x0000_0000.
// =============================================================================
`default_nettype none

module rv32i_core (
    input  wire        i_clk,
    input  wire        i_resetn,
    input  wire        i_soft_rst,
    input  wire [31:0] i_boot_pc,

    // Instruction port (IF stage)
    output wire        o_imem_req,
    output wire [31:0] o_imem_addr,
    input  wire [31:0] i_imem_rdata,
    input  wire        i_imem_ready,

    // Data port (MEM stage)
    output wire        o_dmem_req,
    output wire        o_dmem_we,
    output wire [3:0]  o_dmem_be,
    output wire [31:0] o_dmem_addr,
    output wire [31:0] o_dmem_wdata,
    input  wire [31:0] i_dmem_rdata,
    input  wire        i_dmem_ready,

    // Performance monitor pulse (1 cycle per retired instruction)
    output wire        o_instr_retired
);

    // -------------------------------------------------------------------------
    // Encoding constants
    // -------------------------------------------------------------------------
    localparam [6:0] LP_OPC_LUI    = 7'b0110111;
    localparam [6:0] LP_OPC_AUIPC  = 7'b0010111;
    localparam [6:0] LP_OPC_JAL    = 7'b1101111;
    localparam [6:0] LP_OPC_JALR   = 7'b1100111;
    localparam [6:0] LP_OPC_BRANCH = 7'b1100011;
    localparam [6:0] LP_OPC_LOAD   = 7'b0000011;
    localparam [6:0] LP_OPC_STORE  = 7'b0100011;
    localparam [6:0] LP_OPC_OPIMM  = 7'b0010011;
    localparam [6:0] LP_OPC_OP     = 7'b0110011;

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

    localparam [1:0] LP_WB_ALU = 2'd0;
    localparam [1:0] LP_WB_MEM = 2'd1;
    localparam [1:0] LP_WB_PC4 = 2'd2;

    // -------------------------------------------------------------------------
    // IF / FETCH state
    // -------------------------------------------------------------------------
    reg  [31:0] reg_pc;
    reg         reg_if_busy;      // a fetch request is outstanding on the bus
    reg         reg_discard;      // drop the next fetch response (flush)
    reg         reg_fbuf_valid;
    reg  [31:0] reg_fbuf_instr;
    reg  [31:0] reg_fbuf_pc;

    // IF/ID
    reg         reg_ifid_valid;
    reg  [31:0] reg_ifid_instr;
    reg  [31:0] reg_ifid_pc;

    // ID/EX
    reg         reg_idex_valid;
    reg  [31:0] reg_idex_pc;
    reg  [31:0] reg_idex_rs1_data;
    reg  [31:0] reg_idex_rs2_data;
    reg  [4:0]  reg_idex_rs1;
    reg  [4:0]  reg_idex_rs2;
    reg  [4:0]  reg_idex_rd;
    reg  [31:0] reg_idex_imm;
    reg  [2:0]  reg_idex_funct3;
    reg         reg_idex_alusrc_pc;
    reg         reg_idex_alusrc_imm;
    reg  [3:0]  reg_idex_aluop;
    reg         reg_idex_regwrite;
    reg         reg_idex_memread;
    reg         reg_idex_memwrite;
    reg         reg_idex_branch;
    reg         reg_idex_jump;
    reg         reg_idex_jalr;
    reg  [1:0]  reg_idex_wbsel;

    // EX/MEM
    reg         reg_exmem_valid;
    reg  [31:0] reg_exmem_result;
    reg  [31:0] reg_exmem_store_data;
    reg  [4:0]  reg_exmem_rd;
    reg  [2:0]  reg_exmem_funct3;
    reg         reg_exmem_regwrite;
    reg         reg_exmem_memread;
    reg         reg_exmem_memwrite;
    reg  [1:0]  reg_exmem_wbsel;
    reg  [31:0] reg_exmem_pc4;

    // MEM/WB
    reg         reg_memwb_valid;
    reg  [31:0] reg_memwb_result;
    reg  [31:0] reg_memwb_pc4;
    reg  [4:0]  reg_memwb_rd;
    reg  [2:0]  reg_memwb_funct3;
    reg  [1:0]  reg_memwb_addr_lsb;
    reg         reg_memwb_regwrite;
    reg  [1:0]  reg_memwb_wbsel;
    reg  [31:0] reg_memwb_rdata;
    reg         reg_mem_done;

    // -------------------------------------------------------------------------
    // ID stage: decode
    // -------------------------------------------------------------------------
    wire [6:0] w_opcode   = reg_ifid_instr[6:0];
    wire [2:0] w_funct3   = reg_ifid_instr[14:12];
    wire       w_funct7_5 = reg_ifid_instr[30];
    wire [4:0] w_rs1      = reg_ifid_instr[19:15];
    wire [4:0] w_rs2      = reg_ifid_instr[24:20];
    wire [4:0] w_rd       = reg_ifid_instr[11:7];

    wire [31:0] w_imm_i = {{20{reg_ifid_instr[31]}}, reg_ifid_instr[31:20]};
    wire [31:0] w_imm_s = {{20{reg_ifid_instr[31]}}, reg_ifid_instr[31:25],
                           reg_ifid_instr[11:7]};
    wire [31:0] w_imm_b = {{19{reg_ifid_instr[31]}}, reg_ifid_instr[31],
                           reg_ifid_instr[7], reg_ifid_instr[30:25],
                           reg_ifid_instr[11:8], 1'b0};
    wire [31:0] w_imm_u = {reg_ifid_instr[31:12], 12'd0};
    wire [31:0] w_imm_j = {{11{reg_ifid_instr[31]}}, reg_ifid_instr[31],
                           reg_ifid_instr[19:12], reg_ifid_instr[20],
                           reg_ifid_instr[30:21], 1'b0};

    reg         w_dec_regwrite;
    reg         w_dec_memread;
    reg         w_dec_memwrite;
    reg         w_dec_alusrc_pc;
    reg         w_dec_alusrc_imm;
    reg         w_dec_branch;
    reg         w_dec_jump;
    reg         w_dec_jalr;
    reg  [3:0]  w_dec_aluop;
    reg  [1:0]  w_dec_wbsel;
    reg  [31:0] w_dec_imm;

    always @(*) begin : p_decode
        w_dec_regwrite   = 1'b0;
        w_dec_memread    = 1'b0;
        w_dec_memwrite   = 1'b0;
        w_dec_alusrc_pc  = 1'b0;
        w_dec_alusrc_imm = 1'b0;
        w_dec_branch     = 1'b0;
        w_dec_jump       = 1'b0;
        w_dec_jalr       = 1'b0;
        w_dec_aluop      = LP_ALU_ADD;
        w_dec_wbsel      = LP_WB_ALU;
        w_dec_imm        = 32'd0;

        case (w_opcode)
            LP_OPC_LUI: begin
                w_dec_regwrite   = 1'b1;
                w_dec_alusrc_imm = 1'b1;
                w_dec_aluop      = LP_ALU_PASS;
                w_dec_imm        = w_imm_u;
                w_dec_wbsel      = LP_WB_ALU;
            end
            LP_OPC_AUIPC: begin
                w_dec_regwrite   = 1'b1;
                w_dec_alusrc_pc  = 1'b1;
                w_dec_alusrc_imm = 1'b1;
                w_dec_aluop      = LP_ALU_ADD;
                w_dec_imm        = w_imm_u;
                w_dec_wbsel      = LP_WB_ALU;
            end
            LP_OPC_JAL: begin
                w_dec_regwrite   = 1'b1;
                w_dec_jump       = 1'b1;
                w_dec_imm        = w_imm_j;
                w_dec_wbsel      = LP_WB_PC4;
            end
            LP_OPC_JALR: begin
                w_dec_regwrite   = 1'b1;
                w_dec_jump       = 1'b1;
                w_dec_jalr       = 1'b1;
                w_dec_alusrc_imm = 1'b1;
                w_dec_aluop      = LP_ALU_ADD;
                w_dec_imm        = w_imm_i;
                w_dec_wbsel      = LP_WB_PC4;
            end
            LP_OPC_BRANCH: begin
                w_dec_branch     = 1'b1;
                w_dec_aluop      = LP_ALU_SUB;
                w_dec_imm        = w_imm_b;
            end
            LP_OPC_LOAD: begin
                w_dec_regwrite   = 1'b1;
                w_dec_memread    = 1'b1;
                w_dec_alusrc_imm = 1'b1;
                w_dec_aluop      = LP_ALU_ADD;
                w_dec_imm        = w_imm_i;
                w_dec_wbsel      = LP_WB_MEM;
            end
            LP_OPC_STORE: begin
                w_dec_memwrite   = 1'b1;
                w_dec_alusrc_imm = 1'b1;
                w_dec_aluop      = LP_ALU_ADD;
                w_dec_imm        = w_imm_s;
            end
            LP_OPC_OPIMM: begin
                w_dec_regwrite   = 1'b1;
                w_dec_alusrc_imm = 1'b1;
                w_dec_imm        = w_imm_i;
                w_dec_wbsel      = LP_WB_ALU;
                case (w_funct3)
                    3'b000: w_dec_aluop = LP_ALU_ADD;
                    3'b001: w_dec_aluop = LP_ALU_SLL;
                    3'b010: w_dec_aluop = LP_ALU_SLT;
                    3'b011: w_dec_aluop = LP_ALU_SLTU;
                    3'b100: w_dec_aluop = LP_ALU_XOR;
                    3'b101: w_dec_aluop = w_funct7_5 ? LP_ALU_SRA : LP_ALU_SRL;
                    3'b110: w_dec_aluop = LP_ALU_OR;
                    3'b111: w_dec_aluop = LP_ALU_AND;
                    default: w_dec_aluop = LP_ALU_ADD;
                endcase
            end
            LP_OPC_OP: begin
                w_dec_regwrite = 1'b1;
                w_dec_wbsel    = LP_WB_ALU;
                case (w_funct3)
                    3'b000: w_dec_aluop = w_funct7_5 ? LP_ALU_SUB : LP_ALU_ADD;
                    3'b001: w_dec_aluop = LP_ALU_SLL;
                    3'b010: w_dec_aluop = LP_ALU_SLT;
                    3'b011: w_dec_aluop = LP_ALU_SLTU;
                    3'b100: w_dec_aluop = LP_ALU_XOR;
                    3'b101: w_dec_aluop = w_funct7_5 ? LP_ALU_SRA : LP_ALU_SRL;
                    3'b110: w_dec_aluop = LP_ALU_OR;
                    3'b111: w_dec_aluop = LP_ALU_AND;
                    default: w_dec_aluop = LP_ALU_ADD;
                endcase
            end
            default: begin
                w_dec_regwrite   = 1'b0;
                w_dec_aluop      = LP_ALU_ADD;
                w_dec_wbsel      = LP_WB_ALU;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Register file
    // -------------------------------------------------------------------------
    wire [31:0] w_rs1_data;
    wire [31:0] w_rs2_data;
    wire [31:0] w_wb_data;

    rv32i_regfile u_regfile (
        .i_clk       (i_clk),
        .i_resetn    (i_resetn),
        .i_rs1_addr  (w_rs1),
        .o_rs1_data  (w_rs1_data),
        .i_rs2_addr  (w_rs2),
        .o_rs2_data  (w_rs2_data),
        .i_wb_we     (reg_memwb_valid && reg_memwb_regwrite && !i_soft_rst),
        .i_wb_addr   (reg_memwb_rd),
        .i_wb_data   (w_wb_data)
    );

    // -------------------------------------------------------------------------
    // EX stage: forwarding + ALU + branch resolution
    // -------------------------------------------------------------------------
    wire w_fwd_a_exmem = reg_exmem_valid && reg_exmem_regwrite &&
                         (reg_exmem_rd != 5'd0) && !reg_exmem_memread &&
                         (reg_exmem_rd == reg_idex_rs1);
    wire w_fwd_b_exmem = reg_exmem_valid && reg_exmem_regwrite &&
                         (reg_exmem_rd != 5'd0) && !reg_exmem_memread &&
                         (reg_exmem_rd == reg_idex_rs2);
    wire w_fwd_a_memwb = reg_memwb_valid && reg_memwb_regwrite &&
                         (reg_memwb_rd != 5'd0) &&
                         (reg_memwb_rd == reg_idex_rs1);
    wire w_fwd_b_memwb = reg_memwb_valid && reg_memwb_regwrite &&
                         (reg_memwb_rd != 5'd0) &&
                         (reg_memwb_rd == reg_idex_rs2);

    wire [31:0] w_op_a = w_fwd_a_exmem ? reg_exmem_result :
                         w_fwd_a_memwb ? w_wb_data :
                                         reg_idex_rs1_data;
    wire [31:0] w_op_b = w_fwd_b_exmem ? reg_exmem_result :
                         w_fwd_b_memwb ? w_wb_data :
                                         reg_idex_rs2_data;

    wire [31:0] w_alu_a = reg_idex_alusrc_pc  ? reg_idex_pc  : w_op_a;
    wire [31:0] w_alu_b = reg_idex_alusrc_imm ? reg_idex_imm : w_op_b;

    wire [31:0] w_alu_result;

    rv32i_alu u_alu (
        .i_alu_op (reg_idex_aluop),
        .i_op_a   (w_alu_a),
        .i_op_b   (w_alu_b),
        .o_result (w_alu_result)
    );

    wire w_br_eq  = (w_op_a == w_op_b);
    wire w_br_lt  = ($signed(w_op_a) < $signed(w_op_b));
    wire w_br_ltu = (w_op_a < w_op_b);

    reg w_br_cond;
    always @(*) begin : p_br_cond
        case (reg_idex_funct3)
            3'b000:  w_br_cond =  w_br_eq;      // BEQ
            3'b001:  w_br_cond = ~w_br_eq;      // BNE
            3'b100:  w_br_cond =  w_br_lt;      // BLT
            3'b101:  w_br_cond = ~w_br_lt;      // BGE
            3'b110:  w_br_cond =  w_br_ltu;     // BLTU
            3'b111:  w_br_cond = ~w_br_ltu;     // BGEU
            default: w_br_cond = 1'b0;
        endcase
    end

    wire [31:0] w_pc_plus_imm = reg_idex_pc + reg_idex_imm;
    wire [31:0] w_jalr_target = {w_alu_result[31:1], 1'b0};
    wire [31:0] w_br_target   = reg_idex_jalr ? w_jalr_target : w_pc_plus_imm;

    // -------------------------------------------------------------------------
    // Hazards (split front/back stalls prevent load-use deadlock & ra loss)
    // -------------------------------------------------------------------------
    wire w_load_use = reg_idex_valid && reg_idex_memread &&
                      (reg_idex_rd != 5'd0) && reg_ifid_valid &&
                      ((reg_idex_rd == w_rs1) || (reg_idex_rd == w_rs2));

    wire w_mem_busy = reg_exmem_valid &&
                      (reg_exmem_memread || reg_exmem_memwrite) && !reg_mem_done;

    wire w_stall_back  = w_mem_busy;
    wire w_stall_front = w_mem_busy || w_load_use;

    // Suppress redirect while MEM stage is stalled so JAL/JALR still writes ra
    wire w_br_taken = !w_stall_back && reg_idex_valid &&
                      (reg_idex_jump || (reg_idex_branch && w_br_cond));

    // -------------------------------------------------------------------------
    // MEM stage: store formatting, load extraction, write-back mux
    // -------------------------------------------------------------------------
    reg  [3:0]  w_store_be;
    reg  [31:0] w_store_data;

    always @(*) begin : p_store_fmt
        case (reg_exmem_funct3)
            3'b000: begin                       // SB
                w_store_be   = 4'b0001 << reg_exmem_result[1:0];
                w_store_data = {4{reg_exmem_store_data[7:0]}};
            end
            3'b001: begin                       // SH
                w_store_be   = reg_exmem_result[1] ? 4'b1100 : 4'b0011;
                w_store_data = {2{reg_exmem_store_data[15:0]}};
            end
            default: begin                      // SW
                w_store_be   = 4'b1111;
                w_store_data = reg_exmem_store_data;
            end
        endcase
    end

    assign o_dmem_req   = !i_soft_rst && reg_exmem_valid &&
                          (reg_exmem_memread || reg_exmem_memwrite) &&
                          !reg_mem_done;
    assign o_dmem_we    = reg_exmem_memwrite;
    assign o_dmem_be    = w_store_be;
    assign o_dmem_addr  = reg_exmem_result;
    assign o_dmem_wdata = w_store_data;

    reg [31:0]  w_load_data;
    reg [7:0]   w_load_byte;
    wire [15:0] w_load_half;

    always @(*) begin : p_load_byte
        case (reg_memwb_addr_lsb)
            2'd0:    w_load_byte = reg_memwb_rdata[7:0];
            2'd1:    w_load_byte = reg_memwb_rdata[15:8];
            2'd2:    w_load_byte = reg_memwb_rdata[23:16];
            default: w_load_byte = reg_memwb_rdata[31:24];
        endcase
    end

    assign w_load_half = reg_memwb_addr_lsb[1] ? reg_memwb_rdata[31:16]
                                               : reg_memwb_rdata[15:0];

    always @(*) begin : p_load_ext
        case (reg_memwb_funct3)
            3'b000: w_load_data = {{24{w_load_byte[7]}}, w_load_byte};    // LB
            3'b001: w_load_data = {{16{w_load_half[15]}}, w_load_half};   // LH
            3'b100: w_load_data = {24'd0, w_load_byte};                   // LBU
            3'b101: w_load_data = {16'd0, w_load_half};                   // LHU
            default: w_load_data = reg_memwb_rdata;                       // LW
        endcase
    end

    assign w_wb_data = (reg_memwb_wbsel == LP_WB_MEM) ? w_load_data :
                       (reg_memwb_wbsel == LP_WB_PC4) ? reg_memwb_pc4 :
                                                        reg_memwb_result;

    assign o_instr_retired = reg_memwb_valid && !i_soft_rst;

    // -------------------------------------------------------------------------
    // IF stage control
    // -------------------------------------------------------------------------
    wire w_if_start = !i_soft_rst && !reg_if_busy && !w_stall_front &&
                      !reg_fbuf_valid && !reg_discard && !w_br_taken;

    assign o_imem_req  = !i_soft_rst && (reg_if_busy || w_if_start);
    assign o_imem_addr = reg_pc;

    // -------------------------------------------------------------------------
    // Sequential pipeline (async reset i_resetn + sync watchdog i_soft_rst)
    // -------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_resetn) begin : p_pipeline
        if (!i_resetn) begin
            reg_pc            <= 32'd0;
            reg_if_busy       <= 1'b0;
            reg_discard       <= 1'b0;
            reg_fbuf_valid    <= 1'b0;
            reg_fbuf_instr    <= 32'd0;
            reg_fbuf_pc       <= 32'd0;

            reg_ifid_valid    <= 1'b0;
            reg_ifid_instr    <= 32'd0;
            reg_ifid_pc       <= 32'd0;

            reg_idex_valid      <= 1'b0;
            reg_idex_pc         <= 32'd0;
            reg_idex_rs1_data   <= 32'd0;
            reg_idex_rs2_data   <= 32'd0;
            reg_idex_rs1        <= 5'd0;
            reg_idex_rs2        <= 5'd0;
            reg_idex_rd         <= 5'd0;
            reg_idex_imm        <= 32'd0;
            reg_idex_funct3     <= 3'd0;
            reg_idex_alusrc_pc  <= 1'b0;
            reg_idex_alusrc_imm <= 1'b0;
            reg_idex_aluop      <= 4'd0;
            reg_idex_regwrite   <= 1'b0;
            reg_idex_memread    <= 1'b0;
            reg_idex_memwrite   <= 1'b0;
            reg_idex_branch     <= 1'b0;
            reg_idex_jump       <= 1'b0;
            reg_idex_jalr       <= 1'b0;
            reg_idex_wbsel      <= 2'd0;

            reg_exmem_valid      <= 1'b0;
            reg_exmem_result     <= 32'd0;
            reg_exmem_store_data <= 32'd0;
            reg_exmem_rd         <= 5'd0;
            reg_exmem_funct3     <= 3'd0;
            reg_exmem_regwrite   <= 1'b0;
            reg_exmem_memread    <= 1'b0;
            reg_exmem_memwrite   <= 1'b0;
            reg_exmem_wbsel      <= 2'd0;
            reg_exmem_pc4        <= 32'd0;

            reg_memwb_valid    <= 1'b0;
            reg_memwb_result   <= 32'd0;
            reg_memwb_pc4      <= 32'd0;
            reg_memwb_rd       <= 5'd0;
            reg_memwb_funct3   <= 3'd0;
            reg_memwb_addr_lsb <= 2'd0;
            reg_memwb_regwrite <= 1'b0;
            reg_memwb_wbsel    <= 2'd0;
            reg_memwb_rdata    <= 32'd0;

            reg_mem_done      <= 1'b0;
        end else if (i_soft_rst) begin
            reg_pc             <= i_boot_pc;
            reg_if_busy        <= 1'b0;
            reg_discard        <= 1'b0;
            reg_fbuf_valid     <= 1'b0;
            reg_ifid_valid     <= 1'b0;
            reg_idex_valid     <= 1'b0;
            reg_idex_regwrite  <= 1'b0;
            reg_idex_memread   <= 1'b0;
            reg_idex_memwrite  <= 1'b0;
            reg_idex_branch    <= 1'b0;
            reg_idex_jump      <= 1'b0;
            reg_exmem_valid    <= 1'b0;
            reg_exmem_regwrite <= 1'b0;
            reg_exmem_memread  <= 1'b0;
            reg_exmem_memwrite <= 1'b0;
            reg_memwb_valid    <= 1'b0;
            reg_memwb_regwrite <= 1'b0;
            reg_mem_done       <= 1'b0;
        end else begin
            // -----------------------------------------------------------------
            // MEM/WB <- EX/MEM
            // -----------------------------------------------------------------
            if (!w_stall_back) begin
                reg_memwb_valid    <= reg_exmem_valid;
                reg_memwb_result   <= reg_exmem_result;
                reg_memwb_pc4      <= reg_exmem_pc4;
                reg_memwb_rd       <= reg_exmem_rd;
                reg_memwb_funct3   <= reg_exmem_funct3;
                reg_memwb_addr_lsb <= reg_exmem_result[1:0];
                reg_memwb_regwrite <= reg_exmem_regwrite;
                reg_memwb_wbsel    <= reg_exmem_wbsel;
            end else begin
                reg_memwb_valid    <= 1'b0;
                reg_memwb_regwrite <= 1'b0;
            end

            // -----------------------------------------------------------------
            // EX/MEM <- EX
            // -----------------------------------------------------------------
            if (!w_stall_back) begin
                reg_exmem_valid      <= reg_idex_valid;
                reg_exmem_result     <= w_alu_result;
                reg_exmem_store_data <= w_op_b;
                reg_exmem_rd         <= reg_idex_rd;
                reg_exmem_funct3     <= reg_idex_funct3;
                reg_exmem_regwrite   <= reg_idex_regwrite;
                reg_exmem_memread    <= reg_idex_memread;
                reg_exmem_memwrite   <= reg_idex_memwrite;
                reg_exmem_wbsel      <= reg_idex_wbsel;
                reg_exmem_pc4        <= reg_idex_pc + 32'd4;
            end

            // -----------------------------------------------------------------
            // ID/EX <- ID (bubble on branch redirect or load-use interlock)
            // -----------------------------------------------------------------
            if (!w_stall_back) begin
                if (w_br_taken || w_load_use) begin
                    reg_idex_valid    <= 1'b0;
                    reg_idex_regwrite <= 1'b0;
                    reg_idex_memread  <= 1'b0;
                    reg_idex_memwrite <= 1'b0;
                    reg_idex_branch   <= 1'b0;
                    reg_idex_jump     <= 1'b0;
                end else begin
                    reg_idex_valid      <= reg_ifid_valid;
                    reg_idex_pc         <= reg_ifid_pc;
                    reg_idex_rs1_data   <= w_rs1_data;
                    reg_idex_rs2_data   <= w_rs2_data;
                    reg_idex_rs1        <= w_rs1;
                    reg_idex_rs2        <= w_rs2;
                    reg_idex_rd         <= w_rd;
                    reg_idex_imm        <= w_dec_imm;
                    reg_idex_funct3     <= w_funct3;
                    reg_idex_alusrc_pc  <= w_dec_alusrc_pc;
                    reg_idex_alusrc_imm <= w_dec_alusrc_imm;
                    reg_idex_aluop      <= w_dec_aluop;
                    reg_idex_regwrite   <= w_dec_regwrite;
                    reg_idex_memread    <= w_dec_memread;
                    reg_idex_memwrite   <= w_dec_memwrite;
                    reg_idex_branch     <= w_dec_branch;
                    reg_idex_jump       <= w_dec_jump;
                    reg_idex_jalr       <= w_dec_jalr;
                    reg_idex_wbsel      <= w_dec_wbsel;
                end
            end

            // -----------------------------------------------------------------
            // IF / redirect / fetch buffer
            // -----------------------------------------------------------------
            if (w_br_taken) begin
                reg_pc         <= w_br_target;
                reg_ifid_valid <= 1'b0;
                reg_fbuf_valid <= 1'b0;
                if (reg_if_busy) begin
                    if (i_imem_ready) begin
                        reg_if_busy <= 1'b0;
                        reg_discard <= 1'b0;
                    end else begin
                        reg_discard <= 1'b1;
                    end
                end
            end else begin
                // Feed IF/ID cleanly (single consumption, no double-execution)
                if (reg_fbuf_valid && !w_stall_front) begin
                    reg_ifid_valid <= 1'b1;
                    reg_ifid_instr <= reg_fbuf_instr;
                    reg_ifid_pc    <= reg_fbuf_pc;
                    reg_fbuf_valid <= 1'b0;
                end else if (!w_stall_front) begin
                    if (reg_if_busy && i_imem_ready && !reg_discard) begin
                        reg_ifid_valid <= 1'b1;
                        reg_ifid_instr <= i_imem_rdata;
                        reg_ifid_pc    <= reg_pc;
                    end else begin
                        reg_ifid_valid <= 1'b0;
                    end
                end

                if (reg_if_busy && i_imem_ready) begin
                    reg_if_busy <= 1'b0;
                    if (reg_discard) begin
                        reg_discard <= 1'b0;
                    end else begin
                        reg_pc <= reg_pc + 32'd4;
                        if (w_stall_front) begin
                            reg_fbuf_valid <= 1'b1;
                            reg_fbuf_instr <= i_imem_rdata;
                            reg_fbuf_pc    <= reg_pc;
                        end
                    end
                end

                if (w_if_start) begin
                    reg_if_busy <= 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // Data memory completion flag and data capture
            // -----------------------------------------------------------------
            if (w_mem_busy && i_dmem_ready) begin
                reg_memwb_rdata <= i_dmem_rdata;
                reg_mem_done    <= 1'b1;
            end else if (!w_mem_busy) begin
                reg_mem_done    <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
