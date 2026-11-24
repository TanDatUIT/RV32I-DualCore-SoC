// =============================================================================
// Module      : soc_sysctrl
// Project     : SoC Physical Design Final Project (Dual-Core RV32I SoC)
// Description : System control, lifecycle security, watchdog timer, hardware
//               performance counters (MCYCLE / MINSTRET0 / MINSTRET1), and
//               Dual-Core AMP primitives (HART_ID, CORE1 boot/reset, atomic
//               hardware SPINLOCK, and bidirectional MBOX).
//
// Register map (Base 0x2000_0500, byte offsets):
//   0x00 BOOT_LOCK     [0] lock (RW1S), [1] boot_viol (RO sticky)
//   0x04 WDT_CTRL      [0] en (RW), [1] expired (RO/W1C)
//   0x08 WDT_LOAD      [31:0] watchdog reload value (RW, rst 0xFFFFFFFF)
//   0x0C WDT_KICK      [31:0] write 0x5A5AA5A5 to reload WDT_CNT (W)
//   0x10 WDT_CNT       [31:0] current watchdog down-counter (R)
//   0x14 PERF_CTRL     [0] en (RW, rst 1), [1] clear (W1P)
//   0x18 MCYCLE_LO     [31:0] clock cycle counter (R)
//   0x1C MINSTRET_LO   [31:0] CPU0 retired instruction counter (R)
//   0x20 SOC_ID        [31:0] 0x564D3102 (SoC Revision ID, R)
//   0x24 HART_ID       [1:0] active bus master ID: 0=CPU0, 1=CPU1, 2=DMA (R)
//   0x28 CORE1_CTRL    [0] en (RW), [1] rst_pulse (W1P), [2] spinlock_locked,
//                      [4:3] spinlock_owner, [5] mbox_0to1_valid, [6] mbox_1to0_valid
//   0x2C CORE1_BOOT_PC [31:0] reset vector for CPU1 soft-reset (RW)
//   0x30 SPINLOCK      [0] R: atomic test-and-set (0=acquired, 1=busy); W0: release
//   0x34 MBOX_0TO1     [31:0] mailbox CPU0 -> CPU1 (read by CPU1 clears valid)
//   0x38 MBOX_1TO0     [31:0] mailbox CPU1 -> CPU0 (read by CPU0 clears valid)
//   0x3C MINSTRET1_LO  [31:0] CPU1 retired instruction counter (R)
// =============================================================================
`default_nettype none

module soc_sysctrl (
    input  wire        i_clk,
    input  wire        i_resetn,

    input  wire        i_req,
    input  wire        i_we,
    input  wire [5:0]  i_addr,
    input  wire [31:0] i_wdata,
    input  wire [1:0]  i_master_id,

    output reg  [31:0] o_rdata,
    output wire        o_ready,

    input  wire        i_boot_lock_viol,
    input  wire        i_instr_retired,
    input  wire        i_instr_retired1,

    output wire        o_boot_lock,
    output reg         o_wdt_rst,
    output wire        o_core1_rst,
    output wire [31:0] o_core1_boot_pc
);

    localparam [3:0] LP_REG_BOOT_LOCK   = 4'h0;
    localparam [3:0] LP_REG_WDT_CTRL    = 4'h1;
    localparam [3:0] LP_REG_WDT_LOAD    = 4'h2;
    localparam [3:0] LP_REG_WDT_KICK    = 4'h3;
    localparam [3:0] LP_REG_WDT_CNT     = 4'h4;
    localparam [3:0] LP_REG_PERF_CTRL   = 4'h5;
    localparam [3:0] LP_REG_MCYCLE      = 4'h6;
    localparam [3:0] LP_REG_MINSTRET    = 4'h7;
    localparam [3:0] LP_REG_SOC_ID      = 4'h8;
    localparam [3:0] LP_REG_HART_ID     = 4'h9;
    localparam [3:0] LP_REG_CORE1_CTRL  = 4'hA;
    localparam [3:0] LP_REG_CORE1_PC    = 4'hB;
    localparam [3:0] LP_REG_SPINLOCK    = 4'hC;
    localparam [3:0] LP_REG_MBOX_0TO1   = 4'hD;
    localparam [3:0] LP_REG_MBOX_1TO0   = 4'hE;
    localparam [3:0] LP_REG_MINSTRET1   = 4'hF;

    localparam [31:0] LP_WDT_KEY = 32'h5A5A_A5A5;
    localparam [31:0] LP_SOC_ID  = 32'h564D_3102;

    wire [3:0] w_reg_sel = i_addr[5:2];

    reg        reg_boot_lock;
    reg        reg_boot_viol;
    reg        reg_wdt_en;
    reg        reg_wdt_expired;
    reg [31:0] reg_wdt_load;
    reg [31:0] reg_wdt_cnt;
    reg        reg_perf_en;
    reg [31:0] reg_mcycle;
    reg [31:0] reg_minstret;
    reg [31:0] reg_minstret1;

    // Dual-Core AMP control & IPC state
    reg        reg_core1_en;
    reg        reg_core1_rst_pulse;
    reg [31:0] reg_core1_boot_pc;
    reg        reg_spinlock_locked;
    reg [1:0]  reg_spinlock_owner;
    reg [31:0] reg_mbox_0to1;
    reg        reg_mbox_0to1_valid;
    reg [31:0] reg_mbox_1to0;
    reg        reg_mbox_1to0_valid;

    assign o_ready         = i_req;
    assign o_boot_lock     = reg_boot_lock;
    assign o_core1_rst     = o_wdt_rst || !reg_core1_en || reg_core1_rst_pulse;
    assign o_core1_boot_pc = reg_core1_boot_pc;

    always @(*) begin : p_read
        o_rdata = 32'd0;
        if (!i_we) begin
            case (w_reg_sel)
                LP_REG_BOOT_LOCK : o_rdata = {30'd0, reg_boot_viol, reg_boot_lock};
                LP_REG_WDT_CTRL  : o_rdata = {30'd0, reg_wdt_expired, reg_wdt_en};
                LP_REG_WDT_LOAD  : o_rdata = reg_wdt_load;
                LP_REG_WDT_CNT   : o_rdata = reg_wdt_cnt;
                LP_REG_PERF_CTRL : o_rdata = {31'd0, reg_perf_en};
                LP_REG_MCYCLE    : o_rdata = reg_mcycle;
                LP_REG_MINSTRET  : o_rdata = reg_minstret;
                LP_REG_SOC_ID    : o_rdata = LP_SOC_ID;
                LP_REG_HART_ID   : o_rdata = {30'd0, i_master_id};
                LP_REG_CORE1_CTRL: o_rdata = {25'd0,
                                              reg_mbox_1to0_valid,
                                              reg_mbox_0to1_valid,
                                              reg_spinlock_owner,
                                              reg_spinlock_locked,
                                              1'b0,
                                              reg_core1_en};
                LP_REG_CORE1_PC  : o_rdata = reg_core1_boot_pc;
                LP_REG_SPINLOCK  : o_rdata = {31'd0, reg_spinlock_locked};
                LP_REG_MBOX_0TO1 : o_rdata = reg_mbox_0to1;
                LP_REG_MBOX_1TO0 : o_rdata = reg_mbox_1to0;
                LP_REG_MINSTRET1 : o_rdata = reg_minstret1;
                default          : o_rdata = 32'd0;
            endcase
        end
    end

    always @(posedge i_clk or negedge i_resetn) begin : p_sysctrl
        if (!i_resetn) begin
            reg_boot_lock       <= 1'b0;
            reg_boot_viol       <= 1'b0;
            reg_wdt_en          <= 1'b0;
            reg_wdt_expired     <= 1'b0;
            reg_wdt_load        <= 32'hFFFF_FFFF;
            reg_wdt_cnt         <= 32'hFFFF_FFFF;
            reg_perf_en         <= 1'b1;
            reg_mcycle          <= 32'd0;
            reg_minstret        <= 32'd0;
            reg_minstret1       <= 32'd0;
            o_wdt_rst           <= 1'b0;
            reg_core1_en        <= 1'b0;
            reg_core1_rst_pulse <= 1'b0;
            reg_core1_boot_pc   <= 32'd0;
            reg_spinlock_locked <= 1'b0;
            reg_spinlock_owner  <= 2'd0;
            reg_mbox_0to1       <= 32'd0;
            reg_mbox_0to1_valid <= 1'b0;
            reg_mbox_1to0       <= 32'd0;
            reg_mbox_1to0_valid <= 1'b0;
        end else begin
            o_wdt_rst           <= 1'b0;
            reg_core1_rst_pulse <= 1'b0;

            if (i_boot_lock_viol) begin
                reg_boot_viol <= 1'b1;
            end

            // Performance counters
            if (reg_perf_en) begin
                reg_mcycle <= reg_mcycle + 32'd1;
                if (i_instr_retired) begin
                    reg_minstret <= reg_minstret + 32'd1;
                end
                if (i_instr_retired1) begin
                    reg_minstret1 <= reg_minstret1 + 32'd1;
                end
            end

            // Read side-effects (atomic spinlock acquire + mailbox auto-ack)
            // Block pre-WDT pipelined bus accesses arriving while o_wdt_rst == 1.
            if (i_req && !i_we && !o_wdt_rst) begin
                if ((w_reg_sel == LP_REG_SPINLOCK) && !reg_spinlock_locked) begin
                    reg_spinlock_locked <= 1'b1;
                    reg_spinlock_owner  <= i_master_id;
                end else if ((w_reg_sel == LP_REG_MBOX_0TO1) && (i_master_id == 2'd1)) begin
                    reg_mbox_0to1_valid <= 1'b0;
                end else if ((w_reg_sel == LP_REG_MBOX_1TO0) && (i_master_id == 2'd0)) begin
                    reg_mbox_1to0_valid <= 1'b0;
                end
            end

            // Watchdog down-counter
            if (reg_wdt_en) begin
                if (reg_wdt_cnt == 32'd0) begin
                    o_wdt_rst           <= 1'b1;
                    reg_wdt_expired     <= 1'b1;
                    reg_wdt_en          <= 1'b0;
                    reg_wdt_cnt         <= reg_wdt_load;
                    reg_core1_en        <= 1'b0;
                    reg_core1_rst_pulse <= 1'b0;
                    reg_spinlock_locked <= 1'b0;
                    reg_mbox_0to1_valid <= 1'b0;
                    reg_mbox_1to0_valid <= 1'b0;
                end else begin
                    reg_wdt_cnt <= reg_wdt_cnt - 32'd1;
                end
            end

            // MMIO writes (Watchdog expiration & o_wdt_rst pulse have priority over MMIO writes)
            if (i_req && i_we && !o_wdt_rst && !(reg_wdt_en && (reg_wdt_cnt == 32'd0))) begin
                case (w_reg_sel)
                    LP_REG_BOOT_LOCK: begin
                        if (i_wdata[0]) begin
                            reg_boot_lock <= 1'b1; // Write-1-to-lock (one-way)
                        end
                    end
                    LP_REG_WDT_CTRL: begin
                        if (i_wdata[1]) begin
                            reg_wdt_expired <= 1'b0;
                        end
                        if (i_wdata[0] && !reg_wdt_en) begin
                            reg_wdt_cnt <= reg_wdt_load;
                        end
                        reg_wdt_en <= i_wdata[0];
                    end
                    LP_REG_WDT_LOAD: begin
                        reg_wdt_load <= i_wdata;
                        if (!reg_wdt_en) begin
                            reg_wdt_cnt <= i_wdata;
                        end
                    end
                    LP_REG_WDT_KICK: begin
                        if (i_wdata == LP_WDT_KEY) begin
                            reg_wdt_cnt <= reg_wdt_load;
                        end
                    end
                    LP_REG_PERF_CTRL: begin
                        reg_perf_en <= i_wdata[0];
                        if (i_wdata[1]) begin
                            reg_mcycle    <= 32'd0;
                            reg_minstret  <= 32'd0;
                            reg_minstret1 <= 32'd0;
                        end
                    end
                    LP_REG_CORE1_CTRL: begin
                        reg_core1_en <= i_wdata[0];
                        if (i_wdata[1]) begin
                            reg_core1_rst_pulse <= 1'b1;
                        end
                    end
                    LP_REG_CORE1_PC: begin
                        reg_core1_boot_pc <= i_wdata;
                    end
                    LP_REG_SPINLOCK: begin
                        if (!i_wdata[0]) begin
                            reg_spinlock_locked <= 1'b0;
                        end else begin
                            reg_spinlock_locked <= 1'b1;
                            reg_spinlock_owner  <= i_master_id;
                        end
                    end
                    LP_REG_MBOX_0TO1: begin
                        reg_mbox_0to1       <= i_wdata;
                        reg_mbox_0to1_valid <= 1'b1;
                    end
                    LP_REG_MBOX_1TO0: begin
                        reg_mbox_1to0       <= i_wdata;
                        reg_mbox_1to0_valid <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
